import AppKit
import Foundation
import WakeUpCore

/// Starts jobs for the scheduler: `exec` jobs as child processes (output goes to a log file per
/// execution), `app` jobs by opening the app by its bundle id.
///
/// Every exec job is told its execution id and, if there is one, where to report back:
/// `WAKEUP_EXECUTION_ID` and `WAKEUP_SOCKET` in its environment.
public final class ProcessJobLauncher: JobLauncher {
    public struct LaunchError: Error, LocalizedError, Equatable {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// A deliberately small environment, like the one launchd gives a job. Requests add what they need.
    public static var minimalEnvironment: [String: String] {
        let info = ProcessInfo.processInfo.environment
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = info[key] { environment[key] = value }
        }
        return environment
    }

    private struct Running {
        let process: Process
        let log: FileHandle?
    }

    private let socketPath: String?
    private let logDirectory: URL
    private let baseEnvironment: [String: String]
    private let killAfter: TimeInterval
    private let lock = NSLock()
    private var processes: [String: Running] = [:]
    private var apps: [String: String] = [:]

    /// - Parameters:
    ///   - socketPath: Where jobs report completion. Passed to them as `WAKEUP_SOCKET`.
    ///   - logDirectory: Each exec job's output goes to `<execution id>.log` here.
    ///   - killAfter: After a terminate request, how long a job gets before it is killed.
    public init(
        socketPath: String? = nil,
        logDirectory: URL,
        baseEnvironment: [String: String] = ProcessJobLauncher.minimalEnvironment,
        killAfter: TimeInterval = 10
    ) {
        self.socketPath = socketPath
        self.logDirectory = logDirectory
        self.baseEnvironment = baseEnvironment
        self.killAfter = killAfter
    }

    public func logURL(for executionId: UUID) -> URL {
        logDirectory.appendingPathComponent("\(executionId.uuidString).log")
    }

    // MARK: JobLauncher

    public func launch(_ launch: Launch, executionId: UUID) throws -> String {
        switch launch {
        case .exec(let exec): try launchExec(exec, executionId: executionId)
        case .app(let app): try launchApp(app, executionId: executionId)
        }
    }

    public func status(of handle: String) -> ProcessStatus {
        lock.lock()
        defer { lock.unlock() }
        if let running = processes[handle] {
            if running.process.isRunning { return .running }
            try? running.log?.close()
            if running.process.terminationReason == .uncaughtSignal {
                return .exited(128 + running.process.terminationStatus)
            }
            return .exited(running.process.terminationStatus)
        }
        if let bundleId = apps[handle] {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
            return running ? .running : .exited(nil)
        }
        return .exited(nil)
    }

    public func terminate(handle: String) {
        lock.lock()
        let running = processes[handle]
        let bundleId = apps[handle]
        lock.unlock()

        if let running, running.process.isRunning {
            running.process.terminate()
            let process = running.process
            DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        if let bundleId {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
                app.terminate()
            }
        }
    }

    // MARK: Exec

    private func launchExec(_ exec: ExecLaunch, executionId: UUID) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exec.executable)
        process.arguments = exec.arguments
        if let directory = exec.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        var environment = baseEnvironment
        environment.merge(exec.environment) { _, requested in requested }
        environment["WAKEUP_EXECUTION_ID"] = executionId.uuidString
        if let socketPath { environment["WAKEUP_SOCKET"] = socketPath }
        process.environment = environment

        let log = try openLog(for: executionId)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log

        do {
            try process.run()
        } catch {
            try? log?.close()
            throw LaunchError(message: "Could not start \(exec.executable): \(error.localizedDescription)")
        }

        let handle = "exec:\(process.processIdentifier):\(executionId.uuidString)"
        lock.lock()
        processes[handle] = Running(process: process, log: log)
        lock.unlock()
        return handle
    }

    private func openLog(for executionId: UUID) throws -> FileHandle? {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let url = logURL(for: executionId)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        return try FileHandle(forWritingTo: url)
    }

    // MARK: Apps

    private func launchApp(_ app: AppLaunch, executionId: UUID) throws -> String {
        // `open -b` starts the app by bundle id without needing its location, and returns straight away.
        var arguments = ["-b", app.bundleId]
        if let url = app.url { arguments.append(url) }
        if !app.arguments.isEmpty { arguments.append("--args") }
        arguments.append(contentsOf: app.arguments)

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        let errors = Pipe()
        open.standardError = errors
        do {
            try open.run()
        } catch {
            throw LaunchError(message: "Could not open \(app.bundleId): \(error.localizedDescription)")
        }
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LaunchError(message: "Could not open \(app.bundleId): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let handle = "app:\(app.bundleId):\(executionId.uuidString)"
        lock.lock()
        apps[handle] = app.bundleId
        lock.unlock()
        return handle
    }
}
