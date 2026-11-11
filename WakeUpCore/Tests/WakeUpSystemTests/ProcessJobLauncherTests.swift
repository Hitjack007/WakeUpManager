import Foundation
import Testing
import WakeUpCore
@testable import WakeUpSystem

/// Polls until `condition` is true or the timeout passes.
private func wait(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

private func makeLauncher(socketPath: String? = nil, killAfter: TimeInterval = 10) -> (ProcessJobLauncher, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wakeup-tests-\(UUID().uuidString)")
    return (ProcessJobLauncher(socketPath: socketPath, logDirectory: directory, killAfter: killAfter), directory)
}

@Suite("Process job launcher")
struct ProcessJobLauncherTests {
    @Test func reportsTheExitCodeOfAFinishedJob() throws {
        let (launcher, directory) = makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }

        let handle = try launcher.launch(.exec(ExecLaunch(executable: "/bin/sh", arguments: ["-c", "exit 3"])), executionId: UUID())
        #expect(wait { launcher.status(of: handle) != .running })
        #expect(launcher.status(of: handle) == .exited(3))
    }

    @Test func aSuccessfulJobExitsWithZero() throws {
        let (launcher, directory) = makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }

        let handle = try launcher.launch(.exec(ExecLaunch(executable: "/usr/bin/true")), executionId: UUID())
        #expect(wait { launcher.status(of: handle) == .exited(0) })
    }

    @Test func theJobIsToldItsExecutionIdAndWhereToReport() throws {
        let (launcher, directory) = makeLauncher(socketPath: "/tmp/wakeup-test.sock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()

        let exec = ExecLaunch(executable: "/usr/bin/env", environment: ["MY_SETTING": "yes"])
        let handle = try launcher.launch(.exec(exec), executionId: id)
        #expect(wait { launcher.status(of: handle) != .running })

        let output = try String(contentsOf: launcher.logURL(for: id), encoding: .utf8)
        #expect(output.contains("WAKEUP_EXECUTION_ID=\(id.uuidString)"))
        #expect(output.contains("WAKEUP_SOCKET=/tmp/wakeup-test.sock"))
        #expect(output.contains("MY_SETTING=yes"))
    }

    @Test func theJobStartsWithASmallEnvironment() throws {
        let (launcher, directory) = makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()

        let handle = try launcher.launch(.exec(ExecLaunch(executable: "/usr/bin/env")), executionId: id)
        #expect(wait { launcher.status(of: handle) != .running })

        let output = try String(contentsOf: launcher.logURL(for: id), encoding: .utf8)
        #expect(output.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(!output.contains("/opt/homebrew"))
    }

    @Test func theJobRunsInTheRequestedDirectory() throws {
        let (launcher, directory) = makeLauncher()
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("wakeup-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: workDirectory)
        }
        let id = UUID()

        let handle = try launcher.launch(
            .exec(ExecLaunch(executable: "/bin/pwd", workingDirectory: workDirectory.path)), executionId: id)
        #expect(wait { launcher.status(of: handle) != .running })

        let output = try String(contentsOf: launcher.logURL(for: id), encoding: .utf8)
        // The temporary directory is reached through a /var -> /private/var link, which `pwd` resolves.
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(workDirectory.path))
    }

    @Test func terminatingStopsARunningJob() throws {
        let (launcher, directory) = makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }

        let handle = try launcher.launch(.exec(ExecLaunch(executable: "/bin/sleep", arguments: ["30"])), executionId: UUID())
        #expect(launcher.status(of: handle) == .running)

        launcher.terminate(handle: handle)
        #expect(wait { launcher.status(of: handle) != .running })
        #expect(launcher.status(of: handle) == .exited(128 + SIGTERM))
    }

    @Test func aJobThatIgnoresTerminateIsKilledAfterTheGracePeriod() throws {
        let (launcher, directory) = makeLauncher(killAfter: 0.5)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = "trap '' TERM; while true; do sleep 1; done"
        let handle = try launcher.launch(.exec(ExecLaunch(executable: "/bin/sh", arguments: ["-c", script])), executionId: UUID())
        Thread.sleep(forTimeInterval: 0.3)

        launcher.terminate(handle: handle)
        #expect(wait(timeout: 6) { launcher.status(of: handle) != .running })
        #expect(launcher.status(of: handle) == .exited(128 + SIGKILL))
    }

    @Test func aMissingExecutableFailsToLaunch() {
        let (launcher, directory) = makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ProcessJobLauncher.LaunchError.self) {
            try launcher.launch(.exec(ExecLaunch(executable: "/no/such/program")), executionId: UUID())
        }
    }

    @Test func anUnknownAppFailsToLaunch() {
        let (launcher, directory) = makeLauncher()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: ProcessJobLauncher.LaunchError.self) {
            try launcher.launch(.app(AppLaunch(bundleId: "com.example.no-such-app-\(UUID().uuidString)")), executionId: UUID())
        }
    }

    @Test func anUnknownHandleCountsAsNotRunning() {
        let (launcher, _) = makeLauncher()
        #expect(launcher.status(of: "exec:1:nothing") == .exited(nil))
    }
}
