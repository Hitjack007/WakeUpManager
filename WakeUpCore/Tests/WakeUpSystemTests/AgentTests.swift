import Foundation
import Testing
import WakeUpCore
@testable import WakeUpSystem

private let projectPath = "/Users/mark/Proj"
private let appPath = "/Applications/WakeUpManager.app"

private struct FixedInspector: ProcessInspecting {
    var locations: [String]
    var executable: String?

    func locations(ofProcess pid: Int32) -> [String] { locations }
    func executablePath(ofProcess pid: Int32) -> String? { executable }
}

/// Wakes, the awake hold and the battery, replaced by quiet fakes. Jobs are launched for real.
private final class QuietWorld: WakeBooking, AwakeHolder, PowerSensor, @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var booked: [Date] = []

    var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    var bookedWakes: [Date] { lock.lock(); defer { lock.unlock() }; return booked }

    func book(at date: Date, owner: String) throws { lock.lock(); booked.append(date); lock.unlock() }
    func cancel(at date: Date, owner: String) throws { lock.lock(); booked.removeAll { $0 == date }; lock.unlock() }
    func hold(reason: String) { lock.lock(); held = true; lock.unlock() }
    func release() { lock.lock(); held = false; lock.unlock() }
    func current() -> PowerState { .plugged }
}

private struct Harness {
    let agent: SchedulerAgent
    let client: SocketClient
    let launcher: ProcessJobLauncher
    let world: QuietWorld
    let logDirectory: URL
    let socketPath: String

    func stop() {
        agent.stop()
        try? FileManager.default.removeItem(at: logDirectory)
    }
}

private func makeHarness(
    locations: [String] = [projectPath], executable: String? = "\(appPath)/Contents/MacOS/WakeUpManager"
) throws -> Harness {
    let world = QuietWorld()
    let socketPath = "/tmp/wk-\(UUID().uuidString.prefix(8)).sock"
    let logDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("wakeup-agent-\(UUID().uuidString)")
    let launcher = ProcessJobLauncher(socketPath: socketPath, logDirectory: logDirectory)

    var settings = EngineSettings()
    settings.batteryPollSeconds = 0.2
    settings.startupCheckSeconds = 1
    settings.reportGraceSeconds = 1

    let engine = SchedulerEngine(
        settings: settings,
        ports: EnginePorts(
            wakes: world, awake: world, launcher: launcher, power: world,
            notifier: ClosureNotifier { _ in }, store: InMemoryStateStore()))
    let agent = SchedulerAgent(
        engine: engine,
        inspector: FixedInspector(locations: locations, executable: executable),
        configuration: .init(socketPath: socketPath, trustedControlPaths: [appPath], safetyTickSeconds: 1))
    try agent.start()
    return Harness(
        agent: agent, client: SocketClient(path: socketPath, timeout: 5), launcher: launcher,
        world: world, logDirectory: logDirectory, socketPath: socketPath)
}

private func localTime(secondsFromNow: TimeInterval) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(from: Date().addingTimeInterval(secondsFromNow))
}

private func echoRequest(startingIn seconds: TimeInterval, job: String = "echo") -> WakeRequest {
    WakeRequest(
        client: ClientInfo(displayName: "Proj", path: projectPath),
        jobId: job, name: "Echo",
        schedule: Schedule(start: localTime(secondsFromNow: seconds)),
        estimatedDurationMinutes: 5, expectedCpuPercent: 5, expectedGpuPercent: 0,
        launch: .exec(ExecLaunch(executable: "/bin/echo", arguments: ["hello from the scheduler"])),
        completion: CompletionSpec(reportedBy: .processExit))
}

private func waitUntil(timeout: TimeInterval = 15, _ condition: () throws -> Bool) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return try condition()
}

@Suite("Scheduler agent", .serialized)
struct SchedulerAgentTests {
    @Test func answersPingAndStatusOverTheSocket() throws {
        let harness = try makeHarness()
        defer { harness.stop() }

        #expect(try harness.client.send(.ping()) == .accepted())
        let status = try #require(try harness.client.send(.status()).status)
        #expect(status.executions.isEmpty)
        #expect(!status.holdingAwake)
    }

    @Test func rejectsARequestFromTheWrongLocation() throws {
        let harness = try makeHarness(locations: ["/Users/mark/Somewhere/Else"])
        defer { harness.stop() }

        let reply = try harness.client.send(.submit(echoRequest(startingIn: 60)))
        #expect(!reply.ok)
        #expect(reply.error?.contains("Could not confirm") == true)
    }

    @Test func controlMessagesNeedTheApp() throws {
        let harness = try makeHarness(executable: "/usr/local/bin/wakeup")
        defer { harness.stop() }

        let reply = try harness.client.send(.approveClient(path: projectPath))
        #expect(!reply.ok)
        #expect(reply.error == "Only the WakeUp Manager app can do that.")
    }

    @Test func clientPathsAreMatchedHoweverTheyAreSpelled() throws {
        let harness = try makeHarness()
        defer { harness.stop() }

        var request = echoRequest(startingIn: 120)
        request.client.path = projectPath + "/"
        #expect(try harness.client.send(.submit(request)).response?.status == .pendingApproval)
        #expect(try harness.client.send(.approveClient(path: "/Users/mark/Proj/../Proj")).ok)

        let status = try #require(try harness.client.send(.status()).status)
        #expect(status.clients.map(\.path) == [projectPath])
        #expect(status.clients.first?.status == .approved)
        #expect(status.executions.count == 1)
    }

    @Test func aRequestIsApprovedPlannedRunAndRecorded() throws {
        let harness = try makeHarness()
        defer { harness.stop() }

        // A new client has to be approved first.
        let first = try #require(try harness.client.send(.submit(echoRequest(startingIn: 2))).response)
        #expect(first.status == .pendingApproval)
        #expect(try harness.client.send(.approveClient(path: projectPath)).ok)

        // Once approved, the job is planned, started at its time, and finishes.
        let finished = try waitUntil {
            try harness.client.send(.status()).status?.recentHistory.contains { $0.state == .completed } == true
        }
        #expect(finished)

        let status = try #require(try harness.client.send(.status()).status)
        let run = try #require(status.recentHistory.first)
        #expect(run.state == .completed)
        #expect(run.jobName == "Echo")
        #expect(status.executions.isEmpty)
        #expect(!status.holdingAwake)

        let output = try String(contentsOf: harness.launcher.logURL(for: run.id), encoding: .utf8)
        #expect(output.contains("hello from the scheduler"))
    }

    @Test func aJobThatReportsItselfCanBeFinishedOverTheSocket() throws {
        let harness = try makeHarness()
        defer { harness.stop() }

        var request = echoRequest(startingIn: 1, job: "self-reporting")
        request.launch = .exec(ExecLaunch(executable: "/bin/sleep", arguments: ["30"]))
        request.completion = CompletionSpec(reportedBy: .client)

        _ = try harness.client.send(.submit(request))
        _ = try harness.client.send(.approveClient(path: projectPath))

        // Wait for it to be running, then report completion the way `wakeup done` would.
        var executionId: UUID?
        #expect(try waitUntil {
            executionId = try harness.client.send(.status()).status?.executions.first { $0.state == .running || $0.state == .starting }?.id
            return executionId != nil
        })
        let id = try #require(executionId)
        #expect(try harness.client.send(.status()).status?.holdingAwake == true)

        #expect(try harness.client.send(.complete(CompletionReport(executionId: id, outcome: .success, message: "done"))).ok)
        let status = try #require(try harness.client.send(.status()).status)
        #expect(status.recentHistory.first?.state == .completed)
        #expect(status.recentHistory.first?.message == "done")
        #expect(!status.holdingAwake)
    }

    @Test func aRunningJobCanBeStoppedByTheApp() throws {
        let harness = try makeHarness()
        defer { harness.stop() }

        var request = echoRequest(startingIn: 1, job: "long")
        request.launch = .exec(ExecLaunch(executable: "/bin/sleep", arguments: ["30"]))
        _ = try harness.client.send(.submit(request))
        _ = try harness.client.send(.approveClient(path: projectPath))

        var executionId: UUID?
        #expect(try waitUntil {
            executionId = try harness.client.send(.status()).status?.executions.first { $0.state == .running || $0.state == .starting }?.id
            return executionId != nil
        })
        #expect(try harness.client.send(.stop(executionId: try #require(executionId))).ok)

        let status = try #require(try harness.client.send(.status()).status)
        #expect(status.recentHistory.first?.state == .stopped)
        #expect(!status.holdingAwake)
    }
}
