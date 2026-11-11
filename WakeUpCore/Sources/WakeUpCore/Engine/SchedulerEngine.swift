import Foundation

/// The scheduler's brain. It owns the queue, decides what may run and when, and tells the outside world
/// (through `EnginePorts`) to book wakes, hold the Mac awake, launch jobs and notify the user.
///
/// It never reads the clock itself: every call is given `now`, and `advance(now:)` returns when it next
/// needs to be called. That keeps it deterministic and easy to test. It is not thread-safe; the caller
/// (the scheduler agent) owns it and calls it from one place.
public final class SchedulerEngine {
    public private(set) var state: EngineState
    public var settings: EngineSettings

    private let ports: EnginePorts
    private let resolver: ScheduleResolver
    private var holdingAwake = false
    /// Whether the engine is currently holding the Mac awake.
    public var isHoldingAwake: Bool { holdingAwake }
    /// Jobs already told about a missed run during the current `advance`, so a Mac that was off for
    /// days produces one notice per job rather than one per missed run.
    private var missedNoticed: Set<String> = []

    public init(
        state: EngineState = EngineState(),
        settings: EngineSettings = EngineSettings(),
        ports: EnginePorts,
        resolver: ScheduleResolver = ScheduleResolver()
    ) {
        self.state = state
        var settings = settings
        // What the user set in the app wins over the defaults the agent was started with.
        state.userSettings?.apply(to: &settings)
        self.settings = settings
        self.ports = ports
        self.resolver = resolver
    }

    // MARK: - Settings

    /// The settings as the user has them (or the defaults if they haven't changed anything).
    public var userSettings: SchedulerSettings { state.userSettings ?? SchedulerSettings(from: settings) }

    /// Saves the user's settings and starts using them.
    public func updateUserSettings(_ new: SchedulerSettings) {
        var applied = settings
        new.apply(to: &applied)
        settings = applied
        state.userSettings = SchedulerSettings(from: applied)
        persist()
    }

    // MARK: - Requests

    /// Handles a wake request. `verifiedClientPath` is the client's location as established by the
    /// connection (never taken from the request), and must match `request.client.path`.
    @discardableResult
    public func submit(_ request: WakeRequest, verifiedClientPath: String, now: Date) -> WakeResponse {
        if let stored = state.responses[request.requestId.uuidString] { return stored }
        let response = handle(request, verifiedClientPath: verifiedClientPath, now: now)
        state.responses[request.requestId.uuidString] = response
        if state.responses.count > 1_000 {
            // Old responses only matter for retries; keep the table bounded.
            state.responses = state.responses.filter { $0.key == request.requestId.uuidString }
        }
        persist()
        return response
    }

    private func handle(_ request: WakeRequest, verifiedClientPath: String, now: Date) -> WakeResponse {
        func reject(_ reason: ReasonCode, _ message: String) -> WakeResponse {
            WakeResponse(requestId: request.requestId, status: .rejected, reasonCode: reason, message: message)
        }

        if let problem = RequestValidator.problem(with: request) { return reject(.invalidRequest, problem) }
        guard request.client.path == verifiedClientPath else {
            return reject(.clientLocationMismatch, "The request names a different location than the one it came from.")
        }

        // The first start must not already be too late to run.
        let cutoff = now.addingTimeInterval(-settings.missedGraceSeconds)
        let upcoming: [Date]
        do {
            upcoming = try resolver.occurrences(
                of: request.schedule, after: cutoff.addingTimeInterval(-1), limit: settings.planAhead)
        } catch {
            return reject(.invalidRequest, "The schedule is not valid: \(error).")
        }
        guard !upcoming.isEmpty else { return reject(.invalidRequest, "The schedule has no upcoming start.") }

        var client = state.clients[verifiedClientPath]
            ?? ClientRecord(
                path: verifiedClientPath, displayName: request.client.displayName, status: .pending,
                firstSeen: now, lastRequest: now)
        client.displayName = request.client.displayName
        client.lastRequest = now
        state.clients[verifiedClientPath] = client

        if client.status == .denied {
            return reject(.clientNotApproved, "\(client.displayName) has been denied.")
        }

        // Replace any earlier version of this job.
        let key = JobKey.make(clientPath: verifiedClientPath, jobId: request.jobId)
        let previous = state.jobs[key]
        cancelScheduledExecutions(ofJob: key, now: now)
        var job = JobEntry(
            request: request, clientPath: verifiedClientPath,
            settings: previous?.settings ?? JobPowerSettings(),
            lastPlannedStart: nil)

        if client.status == .pending {
            state.jobs[key] = job
            if !state.notices.contains(where: { $0.kind == .approvalNeeded && $0.jobKey == nil && !$0.resolved && $0.detail.contains(verifiedClientPath) }) {
                addNotice(
                    .approvalNeeded, title: "\(client.displayName) wants to schedule jobs",
                    detail: "\(verifiedClientPath) asked to run \"\(request.name)\". Nothing runs until you approve it.",
                    now: now)
            }
            return WakeResponse(
                requestId: request.requestId, status: .pendingApproval, reasonCode: .clientNotApproved,
                message: "Waiting for you to approve \(client.displayName).")
        }

        let overlaps = overlappingExecutions(for: request, occurrences: upcoming, excludingJob: key)
        if !overlaps.isEmpty {
            job.awaitingConflictDecision = true
            state.jobs[key] = job
            addNotice(
                .conflict, title: "\"\(request.name)\" overlaps another job",
                detail: "It would run at the same time as \(overlaps.map(\.jobName).joined(separator: ", ")). Allow both, or reject the new one.",
                jobKey: key, now: now)
            return WakeResponse(
                requestId: request.requestId, status: .conflict, reasonCode: .overlapsOtherJob,
                message: "Overlaps another job. Waiting for your decision.",
                conflicts: overlaps.map { ConflictInfo(jobId: $0.jobKey, startAt: $0.plannedStart) })
        }

        state.jobs[key] = job
        planUpcoming(now: now)
        reconcileWakes(now: now)
        let first = state.executions.filter { $0.jobKey == key && $0.state == .scheduled }
            .min { $0.plannedStart < $1.plannedStart }
        return WakeResponse(
            requestId: request.requestId, status: .authorised, reasonCode: .ok, message: "Scheduled.",
            plannedWakeAt: first?.wakeAt, plannedStartAt: first?.plannedStart)
    }

    /// Resolves an overlap the user was asked about.
    public func resolveConflict(jobKey: String, allowBoth: Bool, now: Date) {
        guard var job = state.jobs[jobKey], job.awaitingConflictDecision else { return }
        resolveNotices(kind: .conflict, jobKey: jobKey)
        if allowBoth {
            job.awaitingConflictDecision = false
            state.jobs[jobKey] = job
            planUpcoming(now: now)
            reconcileWakes(now: now)
        } else {
            state.jobs[jobKey] = nil
        }
        persist()
    }

    // MARK: - Clients

    public func approveClient(path: String, now: Date) {
        guard var client = state.clients[path] else { return }
        client.status = .approved
        state.clients[path] = client
        resolveNotices(kind: .approvalNeeded, matching: path)
        planUpcoming(now: now)
        reconcileWakes(now: now)
        persist()
    }

    public func denyClient(path: String, now: Date) {
        setClientStatus(.denied, path: path, now: now)
    }

    /// Takes approval back. Everything the client had scheduled is cancelled.
    public func revokeClient(path: String, now: Date) {
        setClientStatus(.denied, path: path, now: now)
    }

    private func setClientStatus(_ status: ClientRecord.Status, path: String, now: Date) {
        guard var client = state.clients[path] else { return }
        client.status = status
        state.clients[path] = client
        resolveNotices(kind: .approvalNeeded, matching: path)
        for (key, job) in state.jobs where job.clientPath == path {
            cancelScheduledExecutions(ofJob: key, now: now)
            terminateActiveExecutions(ofJob: key, now: now, reason: "\(client.displayName) is no longer approved.")
        }
        reconcileWakes(now: now)
        updateHold(now: now)
        persist()
    }

    /// Removes a job and everything planned for it.
    public func cancelJob(key: String, now: Date) {
        cancelScheduledExecutions(ofJob: key, now: now)
        state.jobs[key] = nil
        reconcileWakes(now: now)
        persist()
    }

    public func updateSettings(jobKey: String, to settings: JobPowerSettings) {
        guard var job = state.jobs[jobKey] else { return }
        job.settings = settings
        state.jobs[jobKey] = job
        persist()
    }

    // MARK: - Reports and user decisions

    /// The client's final action. Releases the hold if nothing else needs it.
    public func reportCompletion(_ report: CompletionReport, now: Date) {
        guard let execution = state.executions.first(where: { $0.id == report.executionId }),
              execution.state.isActive else { return }
        switch report.outcome {
        case .success: finish(execution.id, as: .completed, message: report.message, now: now)
        case .partial: finish(execution.id, as: .completed, message: report.message ?? "Partly done.", now: now)
        case .failure: finish(execution.id, as: .failed, message: report.message ?? "The job reported a failure.", now: now)
        }
        if let again = report.reschedule {
            scheduleOneOff(jobKey: execution.jobKey, at: again.startAt, estimatedMinutes: again.estimatedDurationMinutes, now: now)
        }
        reconcileWakes(now: now)
        updateHold(now: now)
        persist()
    }

    /// The user's answer to an overrun notice: let it carry on for longer.
    public func extend(executionId: UUID, minutes: Int, now: Date) {
        guard let index = state.executions.firstIndex(where: { $0.id == executionId }),
              state.executions[index].state.isActive else { return }
        let base = max(state.executions[index].estimateEnd ?? now, now)
        state.executions[index].estimateEnd = base.addingTimeInterval(TimeInterval(minutes * 60))
        state.executions[index].overrunNotified = false
        state.executions[index].state = .running
        resolveNotices(kind: .overrun, executionId: executionId)
        persist()
    }

    /// The user's answer to an overrun notice: stop the job.
    public func stop(executionId: UUID, now: Date) {
        guard let execution = state.executions.first(where: { $0.id == executionId }), execution.state.isActive else { return }
        if let handle = execution.handle { ports.launcher.terminate(handle: handle) }
        finish(executionId, as: .stopped, message: "Stopped by you.", now: now)
        resolveNotices(kind: .overrun, executionId: executionId)
        updateHold(now: now)
        persist()
    }

    // MARK: - Wakes booked by other software

    /// How the audit tells our wakes, Apple's and the user's allowed ones from foreign ones.
    public var wakeOwnerPolicy: WakeOwnerPolicy {
        WakeOwnerPolicy(ourOwners: [settings.wakeOwner], allowedOwners: state.allowedWakeOwners)
    }

    /// Lets an owner tag book its own wakes. The audit leaves its events alone from now on.
    public func allowWakeOwner(_ owner: String) {
        state.allowedWakeOwners.insert(owner)
        resolveNotices(kind: .blockedWake, matching: "\"\(owner)\"")
        persist()
    }

    /// Records that the audit found a wake booked by someone else, and tells the user. Returns `false`
    /// (and does nothing) if that same event was already recorded.
    @discardableResult
    public func recordForeignWake(
        owner: String, kind: String, wakeAt: Date, outcome: BlockedWake.Outcome, detail: String? = nil, now: Date
    ) -> Bool {
        let alreadyKnown = state.blockedWakes.contains {
            $0.owner == owner && $0.kind == kind && $0.wakeAt == wakeAt && $0.outcome == outcome
        }
        guard !alreadyKnown else { return false }

        state.blockedWakes.append(BlockedWake(
            owner: owner, kind: kind, wakeAt: wakeAt, handledAt: now, outcome: outcome, detail: detail))
        if state.blockedWakes.count > settings.maxHistory {
            state.blockedWakes.removeFirst(state.blockedWakes.count - settings.maxHistory)
        }

        let when = wakeAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        switch outcome {
        case .cancelled:
            addNotice(
                .blockedWake, title: "Blocked a wake booked by another app",
                detail: "An event owned by \"\(owner)\" for \(when) was cancelled. It was not one of Apple's.", now: now)
        case .reported:
            addNotice(
                .blockedWake, title: "Another app has booked a wake",
                detail: "An event owned by \"\(owner)\" is booked for \(when). It was left in place.", now: now)
        case .cancelFailed:
            addNotice(
                .blockedWake, title: "Couldn't cancel a wake booked by another app",
                detail: "An event owned by \"\(owner)\" for \(when) is still booked. \(detail ?? "")", now: now)
        }
        persist()
        return true
    }

    public func resolveNotice(id: UUID) {
        guard let index = state.notices.firstIndex(where: { $0.id == id }) else { return }
        state.notices[index].resolved = true
        persist()
    }

    // MARK: - Advancing time

    /// Moves everything forward to `now`. Returns when the engine next needs to be called (`nil` if
    /// nothing is pending).
    @discardableResult
    public func advance(now: Date) -> Date? {
        missedNoticed = []
        advanceActiveExecutions(now: now)
        expireMissedExecutions(now: now)
        planUpcoming(now: now)
        reconcileWakes(now: now)
        startDueExecutions(now: now)
        updateHold(now: now)
        pruneHistory()
        persist()
        return nextDeadline(now: now)
    }

    // MARK: - Planning

    private func isPlannable(_ job: JobEntry) -> Bool {
        state.clients[job.clientPath]?.status == .approved && !job.awaitingConflictDecision
    }

    /// Turns each approved job's upcoming occurrences into scheduled executions, up to `planAhead` ahead.
    private func planUpcoming(now: Date) {
        let cutoff = now.addingTimeInterval(-settings.missedGraceSeconds)
        for key in state.jobs.keys.sorted() {
            guard var job = state.jobs[key], isPlannable(job) else { continue }
            let schedule = job.request.schedule

            // Occurrences that passed unnoticed (the Mac was off, or the scheduler wasn't running).
            if let planned = job.lastPlannedStart,
               let skipped = try? resolver.occurrences(of: schedule, after: planned, limit: 64).filter({ $0 < cutoff }),
               let last = skipped.last {
                var execution = makeExecution(for: job, start: last)
                execution.state = .missed
                execution.endedAt = now
                execution.message = skipped.count == 1
                    ? "Missed: the Mac was off or the scheduler wasn't running."
                    : "Missed \(skipped.count) runs: the Mac was off or the scheduler wasn't running."
                state.history.append(execution)
                if missedNoticed.insert(key).inserted {
                    addNotice(
                        .missed, title: "\"\(job.request.name)\" was skipped",
                        detail: execution.message ?? "", executionId: execution.id, jobKey: key, now: now)
                }
                job.lastPlannedStart = last
            }

            let pending = state.executions.filter { $0.jobKey == key && $0.state == .scheduled }.count
            let room = settings.planAhead - pending
            if room > 0 {
                let after = max(job.lastPlannedStart ?? .distantPast, cutoff.addingTimeInterval(-1))
                if let starts = try? resolver.occurrences(of: schedule, after: after, limit: room) {
                    for start in starts {
                        state.executions.append(makeExecution(for: job, start: start))
                        job.lastPlannedStart = start
                    }
                }
            }
            state.jobs[key] = job
        }
        state.executions.sort { $0.plannedStart < $1.plannedStart }
    }

    private func makeExecution(for job: JobEntry, start: Date, estimatedMinutes: Int? = nil) -> Execution {
        Execution(
            jobKey: job.key, jobName: job.request.name,
            clientName: state.clients[job.clientPath]?.displayName ?? job.request.client.displayName,
            estimatedMinutes: estimatedMinutes ?? job.request.estimatedDurationMinutes,
            plannedStart: start, wakeAt: start.addingTimeInterval(-TimeInterval(settings.leadMinutes * 60)))
    }

    private func scheduleOneOff(jobKey: String, at start: Date, estimatedMinutes: Int, now: Date) {
        guard let job = state.jobs[jobKey], isPlannable(job), start > now else { return }
        state.executions.append(makeExecution(for: job, start: start, estimatedMinutes: estimatedMinutes))
        state.executions.sort { $0.plannedStart < $1.plannedStart }
    }

    /// Scheduled executions of other jobs whose time overlaps one of the new request's occurrences.
    private func overlappingExecutions(for request: WakeRequest, occurrences: [Date], excludingJob key: String) -> [Execution] {
        let length = TimeInterval(request.estimatedDurationMinutes * 60)
        return state.executions.filter { other in
            guard other.state == .scheduled, other.jobKey != key else { return false }
            let otherLength = TimeInterval(other.estimatedMinutes * 60)
            return occurrences.contains { start in
                start < other.plannedStart.addingTimeInterval(otherLength) && other.plannedStart < start.addingTimeInterval(length)
            }
        }
    }

    private func cancelScheduledExecutions(ofJob key: String, now: Date) {
        for index in state.executions.indices where state.executions[index].jobKey == key && state.executions[index].state == .scheduled {
            state.executions[index].state = .cancelled
            state.executions[index].endedAt = now
        }
        moveFinishedToHistory()
    }

    private func terminateActiveExecutions(ofJob key: String, now: Date, reason: String) {
        for execution in state.executions where execution.jobKey == key && execution.state.isActive {
            if let handle = execution.handle { ports.launcher.terminate(handle: handle) }
            finish(execution.id, as: .stopped, message: reason, now: now)
        }
    }

    // MARK: - Wake booking

    /// Makes the booked wakes match the scheduled executions.
    private func reconcileWakes(now: Date) {
        let desired = neededWakes(now: now)
        for wake in state.bookedWakes where !desired.contains(wake) {
            // A wake that has already fired can't be cancelled; just forget it.
            if wake > now { try? ports.wakes.cancel(at: wake, owner: settings.wakeOwner) }
            state.bookedWakes.remove(wake)
        }
        for wake in desired.sorted() where !state.bookedWakes.contains(wake) {
            do {
                try ports.wakes.book(at: wake, owner: settings.wakeOwner)
                state.bookedWakes.insert(wake)
                resolveNotices(kind: .wakeBookingFailed)
            } catch {
                let alreadyTold = state.notices.contains { $0.kind == .wakeBookingFailed && !$0.resolved }
                if !alreadyTold {
                    addNotice(
                        .wakeBookingFailed, title: "Couldn't book a wake",
                        detail: "The Mac may not wake for an upcoming job. \(error.localizedDescription)", now: now)
                }
            }
        }
    }

    /// The wakes that have to be booked. A job whose wake falls while an earlier job is expected to be
    /// holding the Mac awake needs none of its own.
    private func neededWakes(now: Date) -> Set<Date> {
        let upcoming = state.executions
            .filter { $0.state == .scheduled && $0.wakeAt > now }
            .sorted { $0.wakeAt < $1.wakeAt }
        guard settings.mergeNearbyWakes else { return Set(upcoming.map(\.wakeAt)) }

        // The Mac is held awake until `coveredUntil`, by what is running (or already woken for) now and by
        // the wakes kept so far.
        var coveredUntil = state.executions
            .filter { $0.state.isActive || ($0.state == .scheduled && $0.wakeAt <= now) }
            .map { $0.estimateEnd ?? $0.plannedStart.addingTimeInterval(TimeInterval($0.estimatedMinutes * 60)) }
            .max() ?? .distantPast
        var needed: Set<Date> = []
        for execution in upcoming {
            if execution.wakeAt > coveredUntil { needed.insert(execution.wakeAt) }
            let end = execution.plannedStart.addingTimeInterval(TimeInterval(execution.estimatedMinutes * 60))
            coveredUntil = max(coveredUntil, end)
        }
        return needed
    }

    /// While a job runs, keeps a wake booked a few minutes ahead, moved forward every couple of minutes.
    private func updateSafetyWake(now: Date) {
        guard state.executions.contains(where: { $0.state.isActive }) else {
            clearSafetyWake(now: now)
            return
        }
        if let current = state.safetyWake,
           now < current.addingTimeInterval(settings.safetyWakeRefreshSeconds - settings.safetyWakeAheadSeconds) {
            return
        }
        let next = now.addingTimeInterval(settings.safetyWakeAheadSeconds)
        guard (try? ports.wakes.book(at: next, owner: settings.wakeOwner)) != nil else { return }
        clearSafetyWake(now: now)
        state.safetyWake = next
    }

    private func clearSafetyWake(now: Date) {
        guard let old = state.safetyWake else { return }
        // One that has already fired can't be cancelled; just forget it.
        if old > now { try? ports.wakes.cancel(at: old, owner: settings.wakeOwner) }
        state.safetyWake = nil
    }

    // MARK: - Starting jobs

    /// Skips scheduled executions that are too late to run, and tells the user once per job.
    private func expireMissedExecutions(now: Date) {
        for id in state.executions.map(\.id) {
            guard let execution = state.executions.first(where: { $0.id == id }),
                  execution.state == .scheduled else { continue }
            let lateness = now.timeIntervalSince(execution.plannedStart)
            guard lateness >= settings.missedGraceSeconds else { continue }

            let reason = execution.blockedBy.map { "The power rules held it back (\($0))." }
                ?? "It was due \(Int(lateness / 60)) minutes ago and the Mac wasn't ready."
            finish(id, as: .missed, message: reason, now: now)
            if missedNoticed.insert(execution.jobKey).inserted {
                addNotice(
                    .missed, title: "\"\(execution.jobName)\" was skipped", detail: reason,
                    executionId: id, jobKey: execution.jobKey, now: now)
            }
        }
    }

    private func startDueExecutions(now: Date) {
        for id in state.executions.map(\.id) {
            guard let index = state.executions.firstIndex(where: { $0.id == id }),
                  state.executions[index].state == .scheduled,
                  state.executions[index].plannedStart <= now else { continue }
            let execution = state.executions[index]

            guard let job = state.jobs[execution.jobKey], isPlannable(job) else {
                finish(id, as: .cancelled, message: "The job is no longer scheduled.", now: now)
                continue
            }

            let level = job.request.intensityLevel(thresholds: settings.thresholds)
            switch PowerPolicy.evaluate(level: level, power: ports.power.current(), policy: settings.battery, job: job.settings) {
            case .deny(let reason):
                state.executions[index].blockedBy = reason.rawValue
                continue
            case .allow:
                break
            }

            do {
                let handle = try ports.launcher.launch(job.request.launch, executionId: id)
                state.executions[index].state = .starting
                state.executions[index].startedAt = now
                state.executions[index].estimateEnd = now.addingTimeInterval(TimeInterval(execution.estimatedMinutes * 60))
                state.executions[index].handle = handle
                state.executions[index].blockedBy = nil
            } catch {
                finish(id, as: .failed, message: "Could not start: \(error.localizedDescription)", now: now)
                addNotice(
                    .failed, title: "\"\(execution.jobName)\" could not start",
                    detail: error.localizedDescription, executionId: id, jobKey: execution.jobKey, now: now)
            }
        }
    }

    // MARK: - Watching running jobs

    private func advanceActiveExecutions(now: Date) {
        for id in state.executions.map(\.id) {
            guard let index = state.executions.firstIndex(where: { $0.id == id }),
                  state.executions[index].state.isActive,
                  let job = state.jobs[state.executions[index].jobKey] else {
                if let index = state.executions.firstIndex(where: { $0.id == id }), state.executions[index].state.isActive {
                    finish(id, as: .stopped, message: "The job was removed.", now: now)
                }
                continue
            }
            let execution = state.executions[index]
            let status = execution.handle.map { ports.launcher.status(of: $0) } ?? .exited(nil)

            // The power rules apply while a job runs too.
            if PowerPolicy.shouldTerminateRunningJob(power: ports.power.current(), policy: settings.battery, job: job.settings) {
                if let handle = execution.handle { ports.launcher.terminate(handle: handle) }
                finish(id, as: .stopped, message: "Stopped because the battery fell too low.", now: now)
                addNotice(
                    .batteryStopped, title: "\"\(execution.jobName)\" was stopped",
                    detail: "The battery fell below the limit while it was running.", executionId: id, jobKey: execution.jobKey, now: now)
                continue
            }

            switch status {
            case .running:
                if execution.state == .starting { state.executions[index].state = .running }
                if execution.state == .starting,
                   let started = execution.startedAt, now.timeIntervalSince(started) < settings.startupCheckSeconds {
                    break
                }
                if let end = state.executions[index].estimateEnd, now >= end, !state.executions[index].overrunNotified {
                    state.executions[index].state = .overrun
                    state.executions[index].overrunNotified = true
                    addNotice(
                        .overrun, title: "\"\(execution.jobName)\" is still going",
                        detail: "It is past its \(execution.estimatedMinutes) minute estimate. The Mac is still being held awake. Extend it or stop it.",
                        executionId: id, jobKey: execution.jobKey, now: now)
                }
            case .exited(let code):
                handleExit(index: index, code: code, request: job.request, now: now)
            }
        }
    }

    private func handleExit(index: Int, code: Int32?, request: WakeRequest, now: Date) {
        let execution = state.executions[index]
        let id = execution.id
        var isApp = false
        if case .app = request.launch { isApp = true }

        // An app takes a moment to appear after it is opened, so don't judge it too early.
        if isApp, execution.state == .starting,
           let started = execution.startedAt, now.timeIntervalSince(started) < settings.startupCheckSeconds {
            return
        }

        switch request.completion.reportedBy {
        case .processExit:
            if code == 0 {
                finish(id, as: .completed, message: nil, now: now)
            } else {
                let detail = code.map { "Exited with status \($0)." } ?? "Exited."
                finish(id, as: .failed, message: detail, now: now)
                addNotice(.failed, title: "\"\(execution.jobName)\" failed", detail: detail, executionId: id, jobKey: execution.jobKey, now: now)
            }
        case .appQuit:
            if execution.state == .starting {
                failToStart(execution, now: now)
            } else {
                finish(id, as: .completed, message: nil, now: now)
            }
        case .client:
            // An app that never showed up as running did not start; no report is coming.
            if isApp && execution.state == .starting {
                failToStart(execution, now: now)
                return
            }
            // Otherwise give a late completion report a moment to arrive before calling it a failure.
            if state.executions[index].exitedAt == nil { state.executions[index].exitedAt = now }
            guard let exited = state.executions[index].exitedAt,
                  now.timeIntervalSince(exited) >= settings.reportGraceSeconds else { return }
            let detail = "It exited without reporting that it had finished."
            finish(id, as: .failed, message: detail, now: now)
            addNotice(.failed, title: "\"\(execution.jobName)\" failed", detail: detail, executionId: id, jobKey: execution.jobKey, now: now)
        }
    }

    private func failToStart(_ execution: Execution, now: Date) {
        finish(execution.id, as: .didNotStart, message: "It never started running.", now: now)
        addNotice(
            .didNotStart, title: "\"\(execution.jobName)\" did not start",
            detail: "It was launched but never showed up as running, so the Mac is no longer being held awake for it.",
            executionId: execution.id, jobKey: execution.jobKey, now: now)
    }

    // MARK: - Finishing

    private func finish(_ id: UUID, as newState: Execution.State, message: String?, now: Date) {
        guard let index = state.executions.firstIndex(where: { $0.id == id }) else { return }
        state.executions[index].state = newState
        state.executions[index].endedAt = now
        if let message { state.executions[index].message = message }
        moveFinishedToHistory()
    }

    private func moveFinishedToHistory() {
        let finished = state.executions.filter { $0.state.isFinished }
        guard !finished.isEmpty else { return }
        state.history.append(contentsOf: finished)
        state.executions.removeAll { $0.state.isFinished }
    }

    private func pruneHistory() {
        if state.history.count > settings.maxHistory {
            state.history.removeFirst(state.history.count - settings.maxHistory)
        }
        if state.notices.count > settings.maxHistory {
            var excess = state.notices.count - settings.maxHistory
            state.notices.removeAll { notice in
                guard excess > 0, notice.resolved else { return false }
                excess -= 1
                return true
            }
        }
    }

    // MARK: - Holding the Mac awake

    private func updateHold(now: Date) {
        updateSafetyWake(now: now)
        let anyActive = state.executions.contains { $0.state.isActive }
        let waking = state.executions.contains { execution in
            guard execution.state == .scheduled,
                  now.timeIntervalSince(execution.plannedStart) < settings.missedGraceSeconds else { return false }
            if execution.wakeAt <= now { return true }
            // Already holding for a job that just finished: bridge a short gap to the next one.
            return holdingAwake && execution.plannedStart.timeIntervalSince(now) <= settings.keepAwakeGapSeconds
        }
        let needed = anyActive || waking
        if needed && !holdingAwake {
            ports.awake.hold(reason: holdReason())
            holdingAwake = true
        } else if !needed && holdingAwake {
            ports.awake.release()
            holdingAwake = false
        } else if needed {
            ports.awake.hold(reason: holdReason())
        }
    }

    private func holdReason() -> String {
        if let running = state.executions.first(where: { $0.state.isActive }) {
            return "Running \(running.jobName)"
        }
        return "Preparing for the next job"
    }

    // MARK: - Deadlines

    private func nextDeadline(now: Date) -> Date? {
        var candidates: [Date] = []
        for execution in state.executions {
            switch execution.state {
            case .scheduled:
                if execution.wakeAt > now { candidates.append(execution.wakeAt) }
                if execution.plannedStart > now {
                    candidates.append(execution.plannedStart)
                } else {
                    candidates.append(execution.plannedStart.addingTimeInterval(settings.missedGraceSeconds))
                    if execution.blockedBy != nil { candidates.append(now.addingTimeInterval(settings.batteryPollSeconds)) }
                }
            case .starting:
                if let started = execution.startedAt { candidates.append(started.addingTimeInterval(settings.startupCheckSeconds)) }
                candidates.append(now.addingTimeInterval(settings.batteryPollSeconds))
            case .running:
                if let end = execution.estimateEnd, end > now { candidates.append(end) }
                candidates.append(now.addingTimeInterval(settings.batteryPollSeconds))
            case .overrun:
                candidates.append(now.addingTimeInterval(settings.batteryPollSeconds))
            default:
                break
            }
            if let exited = execution.exitedAt {
                candidates.append(exited.addingTimeInterval(settings.reportGraceSeconds))
            }
        }
        if let safety = state.safetyWake {
            candidates.append(safety.addingTimeInterval(settings.safetyWakeRefreshSeconds - settings.safetyWakeAheadSeconds))
        }
        return candidates.filter { $0 > now }.min()
    }

    // MARK: - Notices and persistence

    private func addNotice(
        _ kind: Notice.Kind, title: String, detail: String,
        executionId: UUID? = nil, jobKey: String? = nil, now: Date
    ) {
        let notice = Notice(kind: kind, title: title, detail: detail, date: now, executionId: executionId, jobKey: jobKey)
        state.notices.append(notice)
        ports.notifier.notify(notice)
    }

    private func resolveNotices(kind: Notice.Kind, jobKey: String? = nil, executionId: UUID? = nil, matching text: String? = nil) {
        for index in state.notices.indices where state.notices[index].kind == kind && !state.notices[index].resolved {
            if let jobKey, state.notices[index].jobKey != jobKey { continue }
            if let executionId, state.notices[index].executionId != executionId { continue }
            if let text, !state.notices[index].detail.contains(text) { continue }
            state.notices[index].resolved = true
        }
    }

    private func persist() {
        try? ports.store.save(state)
    }
}
