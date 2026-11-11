import Foundation
import Testing
import WakeUpCore
@testable import WakeUpSystem

private final class FakeSchedule: ScheduleReading, PowerEventCancelling, @unchecked Sendable {
    private let lock = NSLock()
    var events: [ScheduledPowerEvent] = []
    var failCancel = false
    private(set) var cancelled: [ScheduledPowerEvent] = []

    func scheduledEvents() throws -> [ScheduledPowerEvent] { lock.lock(); defer { lock.unlock() }; return events }

    func cancelEvent(kind: String, at date: Date, owner: String) throws {
        struct Refused: Error, LocalizedError { var errorDescription: String? { "This operation must be run as root" } }
        lock.lock(); defer { lock.unlock() }
        if failCancel { throw Refused() }
        cancelled.append(ScheduledPowerEvent(kind: kind, date: date, owner: owner))
        events.removeAll { $0.kind == kind && $0.date == date && $0.owner == owner }
    }
}

private struct NoInspector: ProcessInspecting {
    func locations(ofProcess pid: Int32) -> [String] { [] }
    func executablePath(ofProcess pid: Int32) -> String? { nil }
}

private let future = Date().addingTimeInterval(3_600)
private let ours = EngineSettings().wakeOwner

private func event(_ owner: String, kind: String = "wake", at date: Date = future) -> ScheduledPowerEvent {
    ScheduledPowerEvent(kind: kind, date: date, owner: owner)
}

/// An agent (not listening on a socket) that audits against `schedule`. One `tick()` runs one audit.
private func makeAgent(_ mode: WakeAuditMode, schedule: FakeSchedule, canceller: Bool = true) -> (SchedulerAgent, SchedulerEngine) {
    let engine = SchedulerEngine(ports: EnginePorts(
        wakes: NullWakes(), awake: NullHold(), launcher: NullLauncher(), power: NullPower(),
        notifier: ClosureNotifier { _ in }, store: InMemoryStateStore()))
    let agent = SchedulerAgent(
        engine: engine, inspector: NoInspector(),
        configuration: .init(
            socketPath: "/tmp/wk-audit-\(UUID().uuidString.prefix(8)).sock", auditMode: mode, auditIntervalSeconds: 0,
            scheduleReader: schedule, eventCanceller: canceller ? schedule : nil))
    return (agent, engine)
}

private struct NullWakes: WakeBooking {
    func book(at date: Date, owner: String) throws {}
    func cancel(at date: Date, owner: String) throws {}
}
private struct NullHold: AwakeHolder {
    func hold(reason: String) {}
    func release() {}
}
private struct NullLauncher: JobLauncher {
    func launch(_ launch: Launch, executionId: UUID) throws -> String { "h" }
    func status(of handle: String) -> ProcessStatus { .running }
    func terminate(handle: String) {}
}
private struct NullPower: PowerSensor {
    func current() -> PowerState { .plugged }
}

@Suite("Auditing wakes booked by other software")
struct WakeAuditTests {
    @Test func cancelModeCancelsOnlyForeignFutureWakes() {
        let schedule = FakeSchedule()
        schedule.events = [
            event("nightshift"), event(ours), event("com.apple.alarm.x"),
            event("nightshift", kind: "sleep"), event("old-job", at: Date().addingTimeInterval(-60)),
        ]
        let (agent, engine) = makeAgent(.cancel, schedule: schedule)
        agent.tick()

        #expect(schedule.cancelled.map(\.owner) == ["nightshift"])
        #expect(schedule.cancelled.map(\.kind) == ["wake"])
        #expect(engine.state.blockedWakes.map(\.outcome) == [.cancelled])
    }

    @Test func reportModeRecordsButLeavesTheWakeBooked() {
        let schedule = FakeSchedule()
        schedule.events = [event("nightshift")]
        let (agent, engine) = makeAgent(.report, schedule: schedule)
        agent.tick()

        #expect(schedule.cancelled.isEmpty)
        #expect(schedule.events.count == 1)
        #expect(engine.state.blockedWakes.map(\.outcome) == [.reported])
    }

    @Test func offModeDoesNothing() {
        let schedule = FakeSchedule()
        schedule.events = [event("nightshift")]
        let (agent, engine) = makeAgent(.off, schedule: schedule)
        agent.tick()

        #expect(schedule.cancelled.isEmpty)
        #expect(engine.state.blockedWakes.isEmpty)
    }

    @Test func aFailedCancelIsRecordedWithTheReason() {
        let schedule = FakeSchedule()
        schedule.events = [event("nightshift")]
        schedule.failCancel = true
        let (agent, engine) = makeAgent(.cancel, schedule: schedule)
        agent.tick()

        let record = engine.state.blockedWakes.first
        #expect(record?.outcome == .cancelFailed)
        #expect(record?.detail?.contains("root") == true)
    }

    @Test func cancelModeWithNoCancellerFallsBackToReporting() {
        let schedule = FakeSchedule()
        schedule.events = [event("nightshift")]
        let (agent, engine) = makeAgent(.cancel, schedule: schedule, canceller: false)
        agent.tick()

        #expect(engine.state.blockedWakes.map(\.outcome) == [.reported])
    }

    @Test func anAllowedOwnerIsLeftAlone() {
        let schedule = FakeSchedule()
        schedule.events = [event("nhl-recorder")]
        let (agent, engine) = makeAgent(.cancel, schedule: schedule)
        engine.allowWakeOwner("nhl-recorder")
        agent.tick()

        #expect(schedule.cancelled.isEmpty)
        #expect(engine.state.blockedWakes.isEmpty)
    }

    @Test func theSameEventIsNotRecordedTwice() {
        let schedule = FakeSchedule()
        schedule.events = [event("nightshift")]
        let (agent, engine) = makeAgent(.report, schedule: schedule)
        agent.tick()
        agent.tick()

        #expect(engine.state.blockedWakes.count == 1)
    }
}
