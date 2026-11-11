import Foundation
import Testing
@testable import WakeUpCore

private func t(_ time: String, seconds: Int = 0) -> Date {
    EngineFixtures.t(time, seconds: seconds)
}

private let client = EngineFixtures.clientPath

private func newEngine(
    _ world: FakeWorld = FakeWorld(), settings: EngineSettings = EngineSettings()
) -> (engine: SchedulerEngine, world: FakeWorld) {
    (EngineFixtures.makeEngine(world: world, settings: settings), world)
}

@Suite("Requests and approval")
struct RequestHandlingTests {
    @Test func anUnknownClientWaitsForApprovalThenIsPlanned() {
        let (engine, world) = newEngine()
        let response = engine.submit(EngineFixtures.request(), verifiedClientPath: client, now: t("06:00"))
        #expect(response.status == .pendingApproval)
        #expect(world.bookedWakes.isEmpty)
        #expect(world.noticeCount(.approvalNeeded) == 1)

        engine.approveClient(path: client, now: t("06:00"))
        #expect(world.bookedWakes == [t("06:55")])
        #expect(engine.state.executions.count == 1)
    }

    @Test func anApprovedClientIsAuthorisedWithPlannedTimes() {
        let (engine, _) = newEngine()
        engine.submit(EngineFixtures.request(job: "first"), verifiedClientPath: client, now: t("06:00"))
        engine.approveClient(path: client, now: t("06:00"))

        let response = engine.submit(EngineFixtures.request(job: "second", start: "2026-11-12T09:00:00"), verifiedClientPath: client, now: t("06:00"))
        #expect(response.status == .authorised)
        #expect(response.plannedStartAt == t("09:00"))
        #expect(response.plannedWakeAt == t("08:55"))
    }

    @Test func aRequestFromADifferentLocationIsRejected() {
        let (engine, world) = newEngine()
        let response = engine.submit(EngineFixtures.request(), verifiedClientPath: "/Users/mark/Other", now: t("06:00"))
        #expect(response.status == .rejected)
        #expect(response.reasonCode == .clientLocationMismatch)
        #expect(engine.state.clients.isEmpty)
        #expect(world.bookedWakes.isEmpty)
    }

    @Test func aDeniedClientIsRejected() {
        let (engine, _) = newEngine()
        engine.submit(EngineFixtures.request(), verifiedClientPath: client, now: t("06:00"))
        engine.denyClient(path: client, now: t("06:00"))
        let response = engine.submit(EngineFixtures.request(job: "other"), verifiedClientPath: client, now: t("06:01"))
        #expect(response.status == .rejected)
        #expect(response.reasonCode == .clientNotApproved)
    }

    @Test func invalidRequestsAreRejected() {
        let (engine, _) = newEngine()
        let cases: [WakeRequest] = [
            EngineFixtures.request(minutes: 0),
            EngineFixtures.request(cpu: 150),
            EngineFixtures.request(launch: .exec(ExecLaunch(executable: "relative/path"))),
            EngineFixtures.request(launch: .app(AppLaunch(bundleId: "com.x")), reporter: .processExit),
            EngineFixtures.request(reporter: .appQuit),
            EngineFixtures.request(start: "2026-11-12T05:00:00"),   // long past
        ]
        for request in cases {
            let response = engine.submit(request, verifiedClientPath: client, now: t("06:00"))
            #expect(response.status == .rejected)
            #expect(response.reasonCode == .invalidRequest)
        }
    }

    @Test func aRepeatedRequestGetsTheSameAnswerWithoutADuplicatePlan() {
        let (engine, world) = newEngine()
        let request = EngineFixtures.request()
        engine.submit(request, verifiedClientPath: client, now: t("06:00"))
        engine.approveClient(path: client, now: t("06:00"))
        let first = engine.submit(request, verifiedClientPath: client, now: t("06:00"))
        let second = engine.submit(request, verifiedClientPath: client, now: t("06:01"))
        #expect(first == second)
        #expect(world.bookedWakes.count == 1)
        #expect(engine.state.executions.count == 1)
    }

    @Test func resubmittingAJobReplacesItsPlan() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        #expect(world.bookedWakes == [t("06:55")])

        engine.submit(EngineFixtures.request(start: "2026-11-12T08:00:00"), verifiedClientPath: client, now: t("06:01"))
        #expect(world.cancelledWakes == [t("06:55")])
        #expect(world.bookedWakes == [t("07:55")])
        #expect(engine.state.executions.filter { $0.state == .scheduled }.count == 1)
    }

    @Test func revokingAClientCancelsItsFutureWork() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.revokeClient(path: client, now: t("06:10"))
        #expect(engine.state.executions.isEmpty)
        #expect(world.cancelledWakes == [t("06:55")])
        #expect(world.bookedWakes.isEmpty)
        #expect(engine.state.history.last?.state == .cancelled)
    }
}

@Suite("Running jobs")
struct RunningJobTests {
    @Test func anExecJobRunsFromWakeToCompletion() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)

        #expect(engine.advance(now: t("06:00")) == t("06:55"))

        // At the wake time the Mac is held awake, but the job has not started.
        engine.advance(now: t("06:55"))
        #expect(world.isHeld)
        #expect(world.launched.isEmpty)

        engine.advance(now: t("07:00"))
        #expect(world.launched.count == 1)
        #expect(engine.state.executions.first?.state == .starting)

        engine.advance(now: t("07:01", seconds: 10))
        #expect(engine.state.executions.first?.state == .running)

        world.statuses[world.lastHandle] = .exited(0)
        engine.advance(now: t("07:20"))
        #expect(engine.state.executions.isEmpty)
        #expect(engine.state.history.last?.state == .completed)
        #expect(!world.isHeld)
        // The only notice is the one asking for the client's approval.
        #expect(world.notices.filter { $0.kind != .approvalNeeded }.isEmpty)
    }

    @Test func aNonZeroExitIsAFailureAndTheUserIsTold() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.advance(now: t("07:00"))
        world.statuses[world.lastHandle] = .exited(3)
        engine.advance(now: t("07:02"))
        #expect(engine.state.history.last?.state == .failed)
        #expect(world.noticeCount(.failed) == 1)
        #expect(!world.isHeld)
    }

    @Test func aLaunchErrorFailsTheExecutionAndReleasesTheHold() {
        let (engine, world) = newEngine()
        world.failLaunch = true
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.advance(now: t("07:00"))
        #expect(engine.state.history.last?.state == .failed)
        #expect(world.noticeCount(.failed) == 1)
        #expect(!world.isHeld)
    }

    @Test func aClientReportedJobEndsWhenItReports() throws {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(reporter: .client), engine: engine)
        engine.advance(now: t("07:00"))
        let id = try #require(world.launched.first?.executionId)

        engine.reportCompletion(CompletionReport(executionId: id, outcome: .success), now: t("07:12"))
        #expect(engine.state.history.last?.state == .completed)
        #expect(!world.isHeld)
    }

    @Test func aReportedFailureIsRecorded() throws {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(reporter: .client), engine: engine)
        engine.advance(now: t("07:00"))
        let id = try #require(world.launched.first?.executionId)
        engine.reportCompletion(CompletionReport(executionId: id, outcome: .failure, message: "disk full"), now: t("07:12"))
        #expect(engine.state.history.last?.state == .failed)
        #expect(engine.state.history.last?.message == "disk full")
    }

    @Test func exitingWithoutReportingIsAFailureAfterAShortGrace() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(reporter: .client), engine: engine)
        engine.advance(now: t("07:00"))
        engine.advance(now: t("07:05"))
        world.statuses[world.lastHandle] = .exited(0)

        engine.advance(now: t("07:10"))                       // noticed, waiting for a late report
        #expect(engine.state.executions.first?.state == .running)
        engine.advance(now: t("07:10", seconds: 5))
        #expect(world.noticeCount(.failed) == 0)
        engine.advance(now: t("07:10", seconds: 11))
        #expect(engine.state.history.last?.state == .failed)
        #expect(world.noticeCount(.failed) == 1)
        #expect(!world.isHeld)
    }

    @Test func aLateReportJustAfterExitStillCountsAsSuccess() throws {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(reporter: .client), engine: engine)
        engine.advance(now: t("07:00"))
        let id = try #require(world.launched.first?.executionId)
        world.statuses[world.lastHandle] = .exited(0)
        engine.advance(now: t("07:10"))
        engine.reportCompletion(CompletionReport(executionId: id, outcome: .success), now: t("07:10", seconds: 3))
        #expect(engine.state.history.last?.state == .completed)
        #expect(world.noticeCount(.failed) == 0)
    }

    @Test func anAppThatNeverRunsDidNotStartAndTheHoldIsReleased() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(
            EngineFixtures.request(launch: .app(AppLaunch(bundleId: "com.example.App")), reporter: .client), engine: engine)
        engine.advance(now: t("07:00"))
        world.statuses[world.lastHandle] = .exited(nil)

        engine.advance(now: t("07:00", seconds: 30))          // still within the startup check
        #expect(engine.state.executions.first?.state == .starting)
        engine.advance(now: t("07:01", seconds: 5))
        #expect(engine.state.history.last?.state == .didNotStart)
        #expect(world.noticeCount(.didNotStart) == 1)
        #expect(!world.isHeld)
    }

    @Test func anAppQuittingCompletesAnAppQuitJob() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(
            EngineFixtures.request(launch: .app(AppLaunch(bundleId: "com.example.App")), reporter: .appQuit), engine: engine)
        engine.advance(now: t("07:00"))
        engine.advance(now: t("07:02"))
        #expect(engine.state.executions.first?.state == .running)
        world.statuses[world.lastHandle] = .exited(nil)
        engine.advance(now: t("07:20"))
        #expect(engine.state.history.last?.state == .completed)
        #expect(!world.isHeld)
    }

    @Test func aReschedulingCompletionPlansAFollowUpAndBooksItsWake() throws {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(reporter: .client), engine: engine)
        engine.advance(now: t("07:00"))
        let id = try #require(world.launched.first?.executionId)

        let again = CompletionReport.Reschedule(startAt: t("09:00"), estimatedDurationMinutes: 15)
        engine.reportCompletion(
            CompletionReport(executionId: id, outcome: .partial, message: "usage limit", reschedule: again), now: t("07:30"))

        let next = try #require(engine.state.executions.first)
        #expect(next.state == .scheduled)
        #expect(next.plannedStart == t("09:00"))
        #expect(next.estimatedMinutes == 15)
        #expect(world.bookedWakes.contains(t("08:55")))
    }
}

@Suite("Overruns")
struct OverrunTests {
    private func runningJob() -> (SchedulerEngine, FakeWorld) {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(minutes: 30, reporter: .client), engine: engine)
        engine.advance(now: t("07:00"))
        engine.advance(now: t("07:01", seconds: 10))
        return (engine, world)
    }

    @Test func overrunningNotifiesOnceAndKeepsRunning() {
        let (engine, world) = runningJob()
        engine.advance(now: t("07:29"))
        #expect(world.noticeCount(.overrun) == 0)
        engine.advance(now: t("07:30", seconds: 5))
        engine.advance(now: t("07:45"))
        #expect(world.noticeCount(.overrun) == 1)
        #expect(engine.state.executions.first?.state == .overrun)
        #expect(world.terminated.isEmpty)
        #expect(world.isHeld)
    }

    @Test func extendingLetsItCarryOnThenNotifiesAgain() throws {
        let (engine, world) = runningJob()
        engine.advance(now: t("07:31"))
        let id = try #require(engine.state.executions.first?.id)

        engine.extend(executionId: id, minutes: 30, now: t("07:32"))
        #expect(engine.state.executions.first?.state == .running)
        engine.advance(now: t("07:50"))
        #expect(world.noticeCount(.overrun) == 1)
        engine.advance(now: t("08:03"))
        #expect(world.noticeCount(.overrun) == 2)
        #expect(world.terminated.isEmpty)
    }

    @Test func stoppingTerminatesTheJobAndReleasesTheHold() throws {
        let (engine, world) = runningJob()
        engine.advance(now: t("07:31"))
        let id = try #require(engine.state.executions.first?.id)

        engine.stop(executionId: id, now: t("07:32"))
        #expect(world.terminated == [world.lastHandle])
        #expect(engine.state.history.last?.state == .stopped)
        #expect(!world.isHeld)
    }
}

@Suite("Power rules")
struct PowerRuleTests {
    private let medium = EngineFixtures.request(cpu: 50)

    @Test func aMediumJobOnLowishBatteryWaitsThenIsSkipped() {
        let (engine, world) = newEngine()
        world.power = PowerState(source: .battery, batteryPercent: 50)
        EngineFixtures.scheduled(medium, engine: engine)

        let deadline = engine.advance(now: t("07:00"))
        #expect(world.launched.isEmpty)
        #expect(engine.state.executions.first?.blockedBy == "batteryTooLowForMedium")
        #expect(deadline == t("07:00", seconds: 30))

        engine.advance(now: t("07:03"))
        #expect(world.launched.isEmpty)

        engine.advance(now: t("07:05"))
        #expect(engine.state.history.last?.state == .missed)
        #expect(engine.state.history.last?.message?.contains("batteryTooLowForMedium") == true)
        #expect(world.noticeCount(.missed) == 1)
        #expect(!world.isHeld)
    }

    @Test func aJobBlockedAtFirstRunsOnceThePowerRulesAllowIt() {
        let (engine, world) = newEngine()
        world.power = PowerState(source: .battery, batteryPercent: 50)
        EngineFixtures.scheduled(medium, engine: engine)
        engine.advance(now: t("07:00"))
        #expect(world.launched.isEmpty)

        world.power = .plugged
        engine.advance(now: t("07:02"))
        #expect(world.launched.count == 1)
    }

    @Test func aMediumJobRunsOnAHighBattery() {
        let (engine, world) = newEngine()
        world.power = PowerState(source: .battery, batteryPercent: 90)
        EngineFixtures.scheduled(medium, engine: engine)
        engine.advance(now: t("07:00"))
        #expect(world.launched.count == 1)
    }

    @Test func aRunningJobIsStoppedWhenTheBatteryFallsBelowTheFloor() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.advance(now: t("07:00"))
        engine.advance(now: t("07:02"))

        world.power = PowerState(source: .battery, batteryPercent: 25)
        engine.advance(now: t("07:05"))
        #expect(world.terminated == [world.lastHandle])
        #expect(engine.state.history.last?.state == .stopped)
        #expect(world.noticeCount(.batteryStopped) == 1)
        #expect(!world.isHeld)
    }

    @Test func aPerJobBatteryGateIsHonoured() {
        let (engine, world) = newEngine()
        world.power = PowerState(source: .battery, batteryPercent: 45)
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.updateSettings(jobKey: EngineFixtures.jobKey, to: JobPowerSettings(minimumBatteryPercent: 60))
        engine.advance(now: t("07:00"))
        #expect(world.launched.isEmpty)
        #expect(engine.state.executions.first?.blockedBy == "batteryBelowJobMinimum")
    }
}

@Suite("Timing and missed jobs")
struct TimingTests {
    @Test func aJobUnderFiveMinutesLateStillRuns() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.advance(now: t("07:03"))
        #expect(world.launched.count == 1)
    }

    @Test func aJobFiveOrMoreMinutesLateIsSkippedAndTheUserIsTold() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.advance(now: t("07:06"))
        #expect(world.launched.isEmpty)
        #expect(engine.state.history.last?.state == .missed)
        #expect(world.noticeCount(.missed) == 1)
        #expect(!world.isHeld)
    }

    @Test func aRecurringJobPlansTheNextOccurrencesAfterEachRun() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(
            EngineFixtures.request(recurrence: Recurrence(frequency: .daily)), engine: engine)
        #expect(engine.state.executions.count == 2)
        #expect(world.bookedWakes == [t("06:55"), t("06:55").addingTimeInterval(86_400)])

        engine.advance(now: t("07:00"))
        world.statuses[world.lastHandle] = .exited(0)
        engine.advance(now: t("07:20"))

        let scheduled = engine.state.executions.filter { $0.state == .scheduled }
        #expect(scheduled.count == 2)
        #expect(scheduled.last?.plannedStart == t("07:00").addingTimeInterval(2 * 86_400))
        #expect(world.bookedWakes.contains(t("06:55").addingTimeInterval(2 * 86_400)))
    }

    @Test func occurrencesMissedWhileOffAreCollapsedIntoOneNotice() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(
            EngineFixtures.request(recurrence: Recurrence(frequency: .daily)), engine: engine)
        // Three days later: the two planned runs and two more have all passed.
        engine.advance(now: t("07:00").addingTimeInterval(3 * 86_400 + 600))
        #expect(world.launched.isEmpty)
        #expect(world.noticeCount(.missed) == 1)
        #expect(engine.state.executions.contains { $0.state == .scheduled && $0.plannedStart > t("07:00").addingTimeInterval(3 * 86_400) })
    }

    @Test func wakeBookingFailuresAreReportedOnceAndRetried() {
        let (engine, world) = newEngine()
        world.failBooking = true
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.advance(now: t("06:01"))
        #expect(world.noticeCount(.wakeBookingFailed) == 1)
        #expect(world.bookedWakes.isEmpty)

        world.failBooking = false
        engine.advance(now: t("06:02"))
        #expect(world.bookedWakes == [t("06:55")])
        #expect(engine.state.notices.filter { $0.kind == .wakeBookingFailed && !$0.resolved }.isEmpty)
    }
}

@Suite("Holding the Mac awake")
struct HoldTests {
    private func twoJobs(secondStart: String) -> (SchedulerEngine, FakeWorld) {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(job: "a", name: "A", minutes: 10), engine: engine)
        engine.submit(EngineFixtures.request(job: "b", name: "B", start: secondStart, minutes: 10), verifiedClientPath: client, now: t("06:00"))
        return (engine, world)
    }

    @Test func aShortGapBetweenJobsIsBridgedWithoutReleasing() {
        let (engine, world) = twoJobs(secondStart: "2026-11-12T07:12:00")
        engine.advance(now: t("07:00"))
        engine.advance(now: t("07:02"))
        world.statuses[world.lastHandle] = .exited(0)
        engine.advance(now: t("07:10"))
        #expect(world.isHeld)
        #expect(world.releaseCount == 0)

        engine.advance(now: t("07:12"))
        #expect(world.launched.count == 2)
    }

    @Test func aLongGapReleasesTheHold() {
        let (engine, world) = twoJobs(secondStart: "2026-11-12T08:00:00")
        engine.advance(now: t("07:00"))
        engine.advance(now: t("07:02"))
        world.statuses[world.lastHandle] = .exited(0)
        engine.advance(now: t("07:10"))
        #expect(!world.isHeld)
        #expect(world.releaseCount == 1)
        #expect(world.bookedWakes.contains(t("07:55")))
    }

    @Test func holdIsNotTakenBeforeTheWakeTime() {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        engine.advance(now: t("06:30"))
        #expect(!world.isHeld)
        engine.advance(now: t("06:55"))
        #expect(world.isHeld)
    }
}

@Suite("Overlaps")
struct ConflictTests {
    private func engineWithJobA() -> (SchedulerEngine, FakeWorld) {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(job: "a", name: "A", minutes: 30), engine: engine)
        return (engine, world)
    }

    private let overlapping = EngineFixtures.request(job: "b", name: "B", start: "2026-11-12T07:15:00", minutes: 30)

    @Test func anOverlapIsNotPlannedUntilTheUserDecides() {
        let (engine, world) = engineWithJobA()
        let response = engine.submit(overlapping, verifiedClientPath: client, now: t("06:00"))
        #expect(response.status == .conflict)
        #expect(response.reasonCode == .overlapsOtherJob)
        #expect(response.conflicts.count == 1)
        #expect(world.noticeCount(.conflict) == 1)
        #expect(!world.bookedWakes.contains(t("07:10")))
        #expect(engine.state.executions.count == 1)
    }

    @Test func allowingBothPlansTheNewJob() {
        let (engine, world) = engineWithJobA()
        engine.submit(overlapping, verifiedClientPath: client, now: t("06:00"))
        engine.resolveConflict(jobKey: JobKey.make(clientPath: client, jobId: "b"), allowBoth: true, now: t("06:01"))
        #expect(engine.state.executions.count == 2)
        // Job A is expected to hold the Mac awake then, so B needs no wake of its own.
        #expect(!world.bookedWakes.contains(t("07:10")))
        #expect(engine.state.notices.filter { $0.kind == .conflict && !$0.resolved }.isEmpty)
    }

    @Test func rejectingTheNewJobRemovesIt() {
        let (engine, world) = engineWithJobA()
        engine.submit(overlapping, verifiedClientPath: client, now: t("06:00"))
        engine.resolveConflict(jobKey: JobKey.make(clientPath: client, jobId: "b"), allowBoth: false, now: t("06:01"))
        #expect(engine.state.executions.count == 1)
        #expect(engine.state.jobs[JobKey.make(clientPath: client, jobId: "b")] == nil)
        #expect(!world.bookedWakes.contains(t("07:10")))
    }

    @Test func jobsThatDoNotOverlapAreAcceptedStraightAway() {
        let (engine, _) = engineWithJobA()
        let apart = EngineFixtures.request(job: "c", name: "C", start: "2026-11-12T07:30:00", minutes: 30)
        #expect(engine.submit(apart, verifiedClientPath: client, now: t("06:00")).status == .authorised)
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test func aRestoredEngineCarriesOnWhereItLeftOff() throws {
        let (engine, world) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(), engine: engine)
        let saved = try #require(world.store.saved)

        let revived = FakeWorld()
        let restored = EngineFixtures.makeEngine(world: revived, state: saved)
        restored.advance(now: t("07:00"))
        #expect(revived.launched.count == 1)
    }

    @Test func theJSONFileStoreRoundTripsTheState() throws {
        let (engine, _) = newEngine()
        EngineFixtures.scheduled(EngineFixtures.request(recurrence: Recurrence(frequency: .daily)), engine: engine)
        engine.advance(now: t("07:00"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStateStore(url: directory.appendingPathComponent("state.json"))

        #expect(try store.load() == nil)
        try store.save(engine.state)
        #expect(try store.load() == engine.state)
    }
}

@Suite("Merging nearby wakes")
struct WakeMergingTests {
    private func twoJobs(secondStart: String, merge: Bool = true) -> (SchedulerEngine, FakeWorld) {
        let world = FakeWorld()
        var settings = EngineSettings()
        settings.mergeNearbyWakes = merge
        let engine = EngineFixtures.makeEngine(world: world, settings: settings)
        EngineFixtures.scheduled(EngineFixtures.request(job: "a", start: "2026-11-12T07:00:00", minutes: 30), engine: engine)
        let response = engine.submit(
            EngineFixtures.request(job: "b", start: "2026-11-12T\(secondStart)", minutes: 30),
            verifiedClientPath: EngineFixtures.clientPath, now: t("06:00"))
        if response.status == .conflict {
            engine.resolveConflict(
                jobKey: JobKey.make(clientPath: EngineFixtures.clientPath, jobId: "b"), allowBoth: true, now: t("06:01"))
        }
        return (engine, world)
    }

    @Test func aJobStartingWhileAnEarlierOneRunsNeedsNoWakeOfItsOwn() {
        let (_, world) = twoJobs(secondStart: "07:20:00")
        #expect(world.bookedWakes == [t("06:55")])
    }

    @Test func aJobAfterTheEarlierOneIsExpectedToEndGetsItsOwnWake() {
        let (_, world) = twoJobs(secondStart: "08:00:00")
        #expect(world.bookedWakes.sorted() == [t("06:55"), t("07:55")])
    }

    @Test func mergingCanBeTurnedOff() {
        let (_, world) = twoJobs(secondStart: "07:20:00", merge: false)
        #expect(world.bookedWakes.sorted() == [t("06:55"), t("07:15")])
    }

    @Test func whenTheEarlierJobEndsEarlyTheLaterWakeIsBooked() {
        let (engine, world) = twoJobs(secondStart: "07:25:00")
        engine.advance(now: t("07:00"))
        #expect(!world.bookedWakes.contains(t("07:20")))

        // A finishes after five minutes: B's wake is booked, since A no longer covers it.
        world.statuses[world.lastHandle] = .exited(0)
        engine.advance(now: t("07:05"))
        #expect(world.bookedWakes.contains(t("07:20")))
    }
}

@Suite("Rolling safety wake")
struct SafetyWakeTests {
    private func runningEngine() -> (SchedulerEngine, FakeWorld) {
        let world = FakeWorld()
        let engine = EngineFixtures.makeEngine(world: world)
        EngineFixtures.scheduled(EngineFixtures.request(minutes: 60), engine: engine)
        engine.advance(now: t("07:00"))
        return (engine, world)
    }

    @Test func aWakeIsBookedFiveMinutesAheadWhileTheJobRuns() {
        let (engine, world) = runningEngine()
        #expect(world.bookedWakes.contains(t("07:05")))
        #expect(engine.state.safetyWake == t("07:05"))
    }

    @Test func itIsMovedForwardEveryTwoMinutes() {
        let (engine, world) = runningEngine()
        engine.advance(now: t("07:01"))
        #expect(engine.state.safetyWake == t("07:05"))

        engine.advance(now: t("07:02"))
        #expect(engine.state.safetyWake == t("07:07"))
        #expect(!world.bookedWakes.contains(t("07:05")))
        #expect(world.bookedWakes.contains(t("07:07")))
    }

    @Test func itIsCancelledWhenTheJobEnds() {
        let (engine, world) = runningEngine()
        world.statuses[world.lastHandle] = .exited(0)
        engine.advance(now: t("07:01"))
        engine.advance(now: t("07:02"))

        #expect(engine.state.safetyWake == nil)
        #expect(!world.bookedWakes.contains(t("07:07")))
    }

    @Test func theEngineAsksToBeWokenInTimeToRefreshIt() {
        let (engine, _) = runningEngine()
        let next = engine.advance(now: t("07:00"))
        #expect(next.map { $0 <= t("07:02") } == true)
    }
}
