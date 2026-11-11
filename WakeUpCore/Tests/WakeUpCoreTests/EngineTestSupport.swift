import Foundation
@testable import WakeUpCore

/// A pretend outside world: records what the engine asks for and lets a test decide how jobs and the
/// battery behave. One object plays every port.
final class FakeWorld: WakeBooking, AwakeHolder, JobLauncher, PowerSensor, UserNotifier {
    // Wakes
    var bookedWakes: [Date] = []
    var cancelledWakes: [Date] = []
    var failBooking = false

    // Awake hold
    private(set) var isHeld = false
    private(set) var holdCount = 0
    private(set) var releaseCount = 0

    // Jobs
    private(set) var launched: [(launch: Launch, executionId: UUID)] = []
    private(set) var terminated: [String] = []
    var statuses: [String: ProcessStatus] = [:]
    var failLaunch = false

    // Power
    var power = PowerState.plugged

    // Notices
    private(set) var notices: [Notice] = []

    let store = InMemoryStateStore()

    struct BookingFailure: Error, LocalizedError {
        var errorDescription: String? { "The helper is not available." }
    }

    struct LaunchFailure: Error, LocalizedError {
        var errorDescription: String? { "No such file." }
    }

    // MARK: WakeBooking

    func book(at date: Date, owner: String) throws {
        if failBooking { throw BookingFailure() }
        bookedWakes.append(date)
    }

    func cancel(at date: Date, owner: String) throws {
        cancelledWakes.append(date)
        bookedWakes.removeAll { $0 == date }
    }

    // MARK: AwakeHolder

    func hold(reason: String) {
        if !isHeld { holdCount += 1 }
        isHeld = true
    }

    func release() {
        if isHeld { releaseCount += 1 }
        isHeld = false
    }

    // MARK: JobLauncher

    func launch(_ launch: Launch, executionId: UUID) throws -> String {
        if failLaunch { throw LaunchFailure() }
        launched.append((launch, executionId))
        let handle = "handle-\(launched.count)"
        statuses[handle] = .running
        return handle
    }

    func status(of handle: String) -> ProcessStatus {
        statuses[handle] ?? .exited(nil)
    }

    func terminate(handle: String) {
        terminated.append(handle)
        statuses[handle] = .exited(nil)
    }

    // MARK: PowerSensor

    func current() -> PowerState { power }

    // MARK: UserNotifier

    func notify(_ notice: Notice) {
        notices.append(notice)
    }

    // MARK: Conveniences for assertions

    var lastHandle: String { "handle-\(launched.count)" }

    func noticeCount(_ kind: Notice.Kind) -> Int {
        notices.filter { $0.kind == kind }.count
    }

    var ports: EnginePorts {
        EnginePorts(wakes: self, awake: self, launcher: self, power: self, notifier: self, store: store)
    }
}

enum EngineFixtures {
    static let clientPath = "/Users/mark/Proj"
    static let auckland = TimeZone(identifier: "Pacific/Auckland")!

    /// An instant on Thursday 12 Nov 2026 (New Zealand daylight time), e.g. `t("07:00")`.
    static func t(_ time: String, seconds: Int = 0) -> Date {
        let padded = time.count == 5 ? time + ":00" : time
        return instant("2026-11-12T\(padded)+13:00").addingTimeInterval(TimeInterval(seconds))
    }

    static func request(
        job: String = "job-1",
        name: String = "Test job",
        start: String = "2026-11-12T07:00:00",
        minutes: Int = 30,
        cpu: Int = 10,
        gpu: Int = 0,
        launch: Launch = .exec(ExecLaunch(executable: "/bin/echo")),
        reporter: CompletionSpec.Reporter = .processExit,
        recurrence: Recurrence? = nil,
        client: String = EngineFixtures.clientPath
    ) -> WakeRequest {
        WakeRequest(
            client: ClientInfo(displayName: "Test Client", path: client),
            jobId: job,
            name: name,
            schedule: Schedule(start: start, timeZone: "system", recurrence: recurrence),
            estimatedDurationMinutes: minutes,
            expectedCpuPercent: cpu,
            expectedGpuPercent: gpu,
            launch: launch,
            completion: CompletionSpec(reportedBy: reporter))
    }

    static func makeEngine(world: FakeWorld, state: EngineState = EngineState(), settings: EngineSettings = EngineSettings()) -> SchedulerEngine {
        SchedulerEngine(
            state: state, settings: settings, ports: world.ports,
            resolver: ScheduleResolver(systemTimeZone: auckland))
    }

    /// An engine whose client is already approved and which has accepted `request`.
    @discardableResult
    static func scheduled(
        _ request: WakeRequest, engine: SchedulerEngine, now: Date = t("06:00")
    ) -> WakeResponse {
        let first = engine.submit(request, verifiedClientPath: request.client.path, now: now)
        if first.status == .pendingApproval {
            engine.approveClient(path: request.client.path, now: now)
        }
        return first
    }

    static var jobKey: String { JobKey.make(clientPath: clientPath, jobId: "job-1") }
}
