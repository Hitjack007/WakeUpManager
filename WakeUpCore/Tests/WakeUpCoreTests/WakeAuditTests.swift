import Foundation
import Testing
@testable import WakeUpCore

private let auckland = TimeZone(identifier: "Pacific/Auckland")!

@Suite("Reading pmset -g sched")
struct PmsetScheduleParserTests {
    private let output = """
    Scheduled power events:
     [0]  wake at 11/12/2026 06:55:00 by 'com.wakeupmanager.scheduler'
     [1]  wake at 11/13/2026 01:13:00 by 'com.apple.alarm.user-invisible-com.apple.calaccessd.travelEngine'
     [2]  shutdown at 11/14/2026 23:00:00 by 'someone with spaces'
    """

    @Test func parsesKindTimeAndOwner() {
        let events = PmsetScheduleParser.parse(output, timeZone: auckland)
        #expect(events.count == 3)
        #expect(events[0] == ScheduledPowerEvent(
            kind: "wake", date: EngineFixtures.t("06:55"), owner: "com.wakeupmanager.scheduler"))
        #expect(events[2].kind == "shutdown")
        #expect(events[2].owner == "someone with spaces")
    }

    @Test func readsTimesInTheGivenZone() {
        let events = PmsetScheduleParser.parse(output, timeZone: auckland)
        #expect(events[1].date == EngineFixtures.t("01:13").addingTimeInterval(86_400))
    }

    @Test func noEventsMeansAnEmptyList() {
        #expect(PmsetScheduleParser.parse("", timeZone: auckland).isEmpty)
        #expect(PmsetScheduleParser.parse("No scheduled events.\n", timeZone: auckland).isEmpty)
    }

    @Test func skipsLinesItCannotRead() {
        let text = " [0]  wake at not-a-date by 'x'\n [1]  wake at 11/12/2026 06:55:00 by 'ok'\n"
        let events = PmsetScheduleParser.parse(text, timeZone: auckland)
        #expect(events.map(\.owner) == ["ok"])
    }
}

@Suite("Whose wake is it")
struct WakeOwnerPolicyTests {
    private let policy = WakeOwnerPolicy(ourOwners: ["com.wakeupmanager.scheduler"], allowedOwners: ["nhl-recorder"])

    @Test func classifiesOwners() {
        #expect(policy.classify(owner: "com.wakeupmanager.scheduler") == .ours)
        #expect(policy.classify(owner: "com.apple.alarm.user-invisible-x") == .apple)
        #expect(policy.classify(owner: "nhl-recorder") == .allowedByUser)
        #expect(policy.classify(owner: "claudewriter-nightshift") == .foreign)
    }

    @Test func ourTagWinsOverTheApplePrefix() {
        let odd = WakeOwnerPolicy(ourOwners: ["com.apple.mine"])
        #expect(odd.classify(owner: "com.apple.mine") == .ours)
    }

    @Test func theApplePrefixMustBeAtTheStart() {
        #expect(policy.classify(owner: "evil.com.apple.thing") == .foreign)
    }
}

@Suite("The engine's record of foreign wakes")
struct ForeignWakeRecordTests {
    private func make() -> (FakeWorld, SchedulerEngine) {
        let world = FakeWorld()
        return (world, EngineFixtures.makeEngine(world: world))
    }

    @Test func recordsOnceAndTellsTheUser() {
        let (world, engine) = make()
        let first = engine.recordForeignWake(
            owner: "nightshift", kind: "wake", wakeAt: EngineFixtures.t("08:00"), outcome: .cancelled, now: EngineFixtures.t("06:00"))
        let again = engine.recordForeignWake(
            owner: "nightshift", kind: "wake", wakeAt: EngineFixtures.t("08:00"), outcome: .cancelled, now: EngineFixtures.t("06:01"))

        #expect(first)
        #expect(!again)
        #expect(engine.state.blockedWakes.count == 1)
        #expect(engine.state.blockedWakes[0].outcome == .cancelled)
        #expect(world.noticeCount(.blockedWake) == 1)
    }

    @Test func eachOutcomeGetsItsOwnNotice() {
        let (world, engine) = make()
        for outcome in [BlockedWake.Outcome.cancelled, .reported, .cancelFailed] {
            engine.recordForeignWake(
                owner: "x", kind: "wake", wakeAt: EngineFixtures.t("08:00"), outcome: outcome, now: EngineFixtures.t("06:00"))
        }
        #expect(engine.state.blockedWakes.count == 3)
        #expect(Set(world.notices.map(\.title)).count == 3)
    }

    @Test func keepsOnlyTheNewestWithinTheHistoryLimit() {
        let world = FakeWorld()
        var settings = EngineSettings()
        settings.maxHistory = 2
        let engine = EngineFixtures.makeEngine(world: world, settings: settings)
        for hour in 8...10 {
            engine.recordForeignWake(
                owner: "x", kind: "wake", wakeAt: EngineFixtures.t(String(format: "%02d:00", hour)),
                outcome: .reported, now: EngineFixtures.t("06:00"))
        }
        #expect(engine.state.blockedWakes.map(\.wakeAt) == [EngineFixtures.t("09:00"), EngineFixtures.t("10:00")])
    }

    @Test func allowingAnOwnerStopsItBeingForeignAndResolvesItsNotices() {
        let (_, engine) = make()
        engine.recordForeignWake(
            owner: "nightshift", kind: "wake", wakeAt: EngineFixtures.t("08:00"), outcome: .reported, now: EngineFixtures.t("06:00"))
        #expect(engine.wakeOwnerPolicy.classify(owner: "nightshift") == .foreign)

        engine.allowWakeOwner("nightshift")

        #expect(engine.wakeOwnerPolicy.classify(owner: "nightshift") == .allowedByUser)
        #expect(engine.state.notices.filter { $0.kind == .blockedWake && !$0.resolved }.isEmpty)
    }

    @Test func theSchedulersOwnTagIsNeverForeign() {
        let (_, engine) = make()
        #expect(engine.wakeOwnerPolicy.classify(owner: EngineSettings().wakeOwner) == .ours)
    }
}

@Suite("State files from before the audit")
struct StateCompatibilityTests {
    @Test func olderStateLoadsWithoutTheNewFields() throws {
        let state = try JSONDecoder().decode(EngineState.self, from: Data("{}".utf8))
        #expect(state.blockedWakes.isEmpty)
        #expect(state.allowedWakeOwners.isEmpty)
    }

    @Test func newFieldsSurviveARoundTrip() throws {
        var state = EngineState()
        state.allowedWakeOwners = ["nhl"]
        state.blockedWakes = [BlockedWake(
            owner: "x", kind: "wake", wakeAt: EngineFixtures.t("08:00"), handledAt: EngineFixtures.t("06:00"), outcome: .cancelFailed, detail: "no root")]
        let decoded = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(state))
        #expect(decoded.allowedWakeOwners == ["nhl"])
        #expect(decoded.blockedWakes == state.blockedWakes)
    }
}
