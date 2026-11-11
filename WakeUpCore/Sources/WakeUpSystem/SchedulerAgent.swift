import Foundation
import WakeUpCore

/// A notifier that hands each notice to a closure. The app shows them as macOS notifications; a plain
/// agent can print or log them.
public struct ClosureNotifier: UserNotifier {
    public var handler: (Notice) -> Void

    public init(_ handler: @escaping (Notice) -> Void) {
        self.handler = handler
    }

    public func notify(_ notice: Notice) {
        handler(notice)
    }
}

extension DispatchWallTime {
    /// A wall-clock deadline, which keeps counting while the Mac sleeps, so a timer set for 07:00 fires
    /// as soon as the Mac wakes after 07:00.
    init(date: Date) {
        let seconds = date.timeIntervalSince1970
        let whole = seconds.rounded(.down)
        self.init(timespec: timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000)))
    }
}

/// What the agent does about wakes booked by other software.
public enum WakeAuditMode: String, Sendable {
    /// Don't look.
    case off
    /// Notice them and tell the user, but leave them in place.
    case report
    /// Cancel them (never Apple's, never the scheduler's own, never an owner the user has allowed).
    case cancel
}

/// Runs the scheduler: owns the engine, listens on the socket, answers clients, and calls the engine again
/// whenever something is due (and at least every few seconds as a safety net).
///
/// All engine access happens on one serial queue.
public final class SchedulerAgent: @unchecked Sendable {
    public struct Configuration {
        public var socketPath: String
        /// Locations whose programs may send control messages (approve, stop, ...). In production, the app.
        public var trustedControlPaths: [String]
        /// The longest the agent goes without checking the engine.
        public var safetyTickSeconds: TimeInterval
        public var auditMode: WakeAuditMode
        /// How often the booked wakes are checked for ones that aren't ours.
        public var auditIntervalSeconds: TimeInterval
        public var scheduleReader: (any ScheduleReading)?
        public var eventCanceller: (any PowerEventCancelling)?

        public init(
            socketPath: String,
            trustedControlPaths: [String] = [],
            safetyTickSeconds: TimeInterval = 30,
            auditMode: WakeAuditMode = .off,
            auditIntervalSeconds: TimeInterval = 30,
            scheduleReader: (any ScheduleReading)? = nil,
            eventCanceller: (any PowerEventCancelling)? = nil
        ) {
            self.socketPath = socketPath
            self.trustedControlPaths = trustedControlPaths
            self.safetyTickSeconds = safetyTickSeconds
            self.auditMode = auditMode
            self.auditIntervalSeconds = auditIntervalSeconds
            self.scheduleReader = scheduleReader
            self.eventCanceller = eventCanceller
        }
    }

    private let engine: SchedulerEngine
    private let verifier: LocationVerifier
    private let configuration: Configuration
    private let clock: @Sendable () -> Date
    private let queue = DispatchQueue(label: "wakeup.agent.engine")
    private var timer: DispatchSourceTimer?
    private var server: UnixSocketServer?
    private var lastAudit = Date.distantPast

    public init(
        engine: SchedulerEngine,
        inspector: any ProcessInspecting = ProcessTreeInspector(),
        configuration: Configuration,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.engine = engine
        self.verifier = LocationVerifier(inspector: inspector)
        self.configuration = configuration
        self.clock = clock
    }

    public func start() throws {
        let server = UnixSocketServer(path: configuration.socketPath) { [weak self] message, pid in
            self?.handle(message, peerProcess: pid) ?? .failure("The scheduler is shutting down.")
        }
        try server.start()
        self.server = server
        queue.sync { rearm(advanceAndAudit(now: clock())) }
    }

    public func stop() {
        server?.stop()
        server = nil
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Advances the engine to now. Called by the timer; also callable directly.
    public func tick() {
        queue.sync { rearm(advanceAndAudit(now: clock())) }
    }

    // MARK: Handling messages

    func handle(_ message: ClientMessage, peerProcess pid: Int32?) -> ServerMessage {
        queue.sync {
            let now = clock()
            let reply = process(message, peerProcess: pid, now: now)
            rearm(advanceAndAudit(now: now))
            return reply
        }
    }

    private func process(_ message: ClientMessage, peerProcess pid: Int32?, now: Date) -> ServerMessage {
        switch message.kind {
        case .ping:
            return .accepted()

        case .status:
            return .report(statusReport())

        case .submit:
            guard var request = message.request else { return .failure("The message has no request.") }
            // Clients are known by one spelling of their location, however the caller wrote it.
            let path = LocationVerifier.canonicalPath(request.client.path)
            guard isVerified(path, peer: pid) else { return .failure(unverifiedMessage(path)) }
            request.client.path = path
            return .answer(engine.submit(request, verifiedClientPath: path, now: now))

        case .complete:
            guard let report = message.report else { return .failure("The message has no completion report.") }
            engine.reportCompletion(report, now: now)
            return .accepted()

        case .cancelJob:
            guard let claimed = message.clientPath, let jobId = message.jobId else {
                return .failure("The message needs a client path and a job id.")
            }
            let path = LocationVerifier.canonicalPath(claimed)
            guard isVerified(path, peer: pid) else { return .failure(unverifiedMessage(path)) }
            engine.cancelJob(key: JobKey.make(clientPath: path, jobId: jobId), now: now)
            return .accepted()

        case .approveClient, .denyClient, .revokeClient, .extend, .stop, .resolveConflict, .resolveNotice,
             .setJobSettings, .allowWakeOwner:
            guard let pid, verifier.isTrusted(peerProcess: pid, trustedPaths: configuration.trustedControlPaths) else {
                return .failure("Only the WakeUp Manager app can do that.")
            }
            return control(message, now: now)
        }
    }

    private func control(_ message: ClientMessage, now: Date) -> ServerMessage {
        switch message.kind {
        case .approveClient:
            guard let path = message.clientPath.map(LocationVerifier.canonicalPath) else { return missing("a client path") }
            engine.approveClient(path: path, now: now)
        case .denyClient:
            guard let path = message.clientPath.map(LocationVerifier.canonicalPath) else { return missing("a client path") }
            engine.denyClient(path: path, now: now)
        case .revokeClient:
            guard let path = message.clientPath.map(LocationVerifier.canonicalPath) else { return missing("a client path") }
            engine.revokeClient(path: path, now: now)
        case .extend:
            guard let id = message.executionId, let minutes = message.minutes else { return missing("an execution id and minutes") }
            engine.extend(executionId: id, minutes: minutes, now: now)
        case .stop:
            guard let id = message.executionId else { return missing("an execution id") }
            engine.stop(executionId: id, now: now)
        case .resolveConflict:
            guard let key = message.jobKey, let allowBoth = message.allowBoth else { return missing("a job key and a decision") }
            engine.resolveConflict(jobKey: key, allowBoth: allowBoth, now: now)
        case .resolveNotice:
            guard let id = message.noticeId else { return missing("a notice id") }
            engine.resolveNotice(id: id)
        case .setJobSettings:
            guard let key = message.jobKey, let settings = message.jobSettings else { return missing("a job key and settings") }
            engine.updateSettings(jobKey: key, to: settings)
        case .allowWakeOwner:
            guard let owner = message.owner, !owner.isEmpty else { return missing("an owner") }
            engine.allowWakeOwner(owner)
        default:
            return .failure("That is not a control message.")
        }
        return .accepted()
    }

    private func missing(_ what: String) -> ServerMessage {
        .failure("The message needs \(what).")
    }

    private func isVerified(_ path: String, peer pid: Int32?) -> Bool {
        guard let pid else { return false }
        return verifier.verifies(claimedPath: path, peerProcess: pid)
    }

    private func unverifiedMessage(_ path: String) -> String {
        "Could not confirm that this request comes from \(path). Run it from inside that folder or app."
    }

    private func statusReport() -> StatusReport {
        let state = engine.state
        return StatusReport(
            holdingAwake: engine.isHoldingAwake,
            clients: state.clients.values.sorted { $0.displayName < $1.displayName },
            executions: state.executions,
            recentHistory: Array(state.history.suffix(20).reversed()),
            openNotices: state.notices.filter { !$0.resolved },
            blockedWakes: Array(state.blockedWakes.suffix(50).reversed()),
            allowedWakeOwners: state.allowedWakeOwners.sorted())
    }

    // MARK: Wakes booked by other software

    private func advanceAndAudit(now: Date) -> Date? {
        auditIfDue(now: now)
        return engine.advance(now: now)
    }

    /// Looks at the booked power events and deals with future wakes that belong to neither the scheduler,
    /// macOS, nor an owner the user has allowed. Only wakes are touched: not sleeps or shutdowns.
    private func auditIfDue(now: Date) {
        guard configuration.auditMode != .off, let reader = configuration.scheduleReader,
              now.timeIntervalSince(lastAudit) >= configuration.auditIntervalSeconds else { return }
        lastAudit = now
        guard let events = try? reader.scheduledEvents() else { return }

        let policy = engine.wakeOwnerPolicy
        let wakeKinds: Set<String> = ["wake", "poweron", "wakepoweron"]
        for event in events where event.date > now && wakeKinds.contains(event.kind) {
            guard policy.classify(owner: event.owner) == .foreign else { continue }

            switch configuration.auditMode {
            case .off:
                break
            case .report:
                engine.recordForeignWake(owner: event.owner, kind: event.kind, wakeAt: event.date, outcome: .reported, now: now)
            case .cancel:
                guard let canceller = configuration.eventCanceller else {
                    engine.recordForeignWake(owner: event.owner, kind: event.kind, wakeAt: event.date, outcome: .reported, now: now)
                    continue
                }
                do {
                    try canceller.cancelEvent(kind: event.kind, at: event.date, owner: event.owner)
                    engine.recordForeignWake(owner: event.owner, kind: event.kind, wakeAt: event.date, outcome: .cancelled, now: now)
                } catch {
                    engine.recordForeignWake(
                        owner: event.owner, kind: event.kind, wakeAt: event.date, outcome: .cancelFailed,
                        detail: error.localizedDescription, now: now)
                }
            }
        }
    }

    // MARK: Timer

    /// Schedules the next engine call for the engine's deadline, or the safety tick if that is sooner.
    /// Must be called on the engine queue.
    private func rearm(_ deadline: Date?) {
        let now = clock()
        var next = now.addingTimeInterval(configuration.safetyTickSeconds)
        if let deadline, deadline < next {
            next = max(deadline, now.addingTimeInterval(0.05))
        }
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(wallDeadline: DispatchWallTime(date: next), leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            rearm(advanceAndAudit(now: clock()))
        }
        source.resume()
        timer = source
    }
}
