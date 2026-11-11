import Foundation
import WakeUpCore

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs a command and waits for it. A protocol so tests can check what would be run.
public protocol CommandRunning {
    func run(_ executable: String, arguments: [String]) throws -> CommandResult
}

public struct ShellCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

public struct PmsetError: Error, LocalizedError, Equatable {
    public var status: Int32
    public var output: String

    public var errorDescription: String? {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "pmset failed (status \(status))" + (detail.isEmpty ? "." : ": \(detail)")
    }
}

/// Books and cancels wakes with `pmset schedule`, which needs root.
///
/// This is the interim route the wake spike and the existing projects use: `sudo -n pmset`, which works
/// only while a passwordless sudo rule for `pmset schedule` exists. It is replaced by the root helper
/// registered with `SMAppService`; the rest of the app only sees the `WakeBooking` protocol.
public struct PmsetWakeBooker: WakeBooking {
    public var runner: any CommandRunning
    public var useSudo: Bool
    public var timeZone: TimeZone

    public init(runner: any CommandRunning = ShellCommandRunner(), useSudo: Bool = true, timeZone: TimeZone = .current) {
        self.runner = runner
        self.useSudo = useSudo
        self.timeZone = timeZone
    }

    public func book(at date: Date, owner: String) throws {
        try runPmset(["schedule", "wake", format(date), owner])
    }

    public func cancel(at date: Date, owner: String) throws {
        try runPmset(["schedule", "cancel", "wake", format(date), owner])
    }

    /// pmset wants local time as `MM/dd/yy HH:mm:ss`.
    func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM/dd/yy HH:mm:ss"
        return formatter.string(from: date)
    }

    private func runPmset(_ arguments: [String]) throws {
        let result = useSudo
            ? try runner.run("/usr/bin/sudo", arguments: ["-n", "/usr/bin/pmset"] + arguments)
            : try runner.run("/usr/bin/pmset", arguments: arguments)
        guard result.status == 0 else { throw PmsetError(status: result.status, output: result.output) }
    }
}

/// Cancels any kind of booked event, which the audit needs for wakes booked by other software.
extension PmsetWakeBooker: PowerEventCancelling {
    public func cancelEvent(kind: String, at date: Date, owner: String) throws {
        try runPmset(["schedule", "cancel", kind, format(date), owner])
    }
}

/// Reads the pending power events with `pmset -g sched` (no privileges needed).
public struct PmsetScheduleReader: ScheduleReading {
    public var runner: any CommandRunning
    public var timeZone: TimeZone

    public init(runner: any CommandRunning = ShellCommandRunner(), timeZone: TimeZone = .current) {
        self.runner = runner
        self.timeZone = timeZone
    }

    public func scheduledEvents() throws -> [ScheduledPowerEvent] {
        let result = try runner.run("/usr/bin/pmset", arguments: ["-g", "sched"])
        guard result.status == 0 else { throw PmsetError(status: result.status, output: result.output) }
        return PmsetScheduleParser.parse(result.output, timeZone: timeZone)
    }
}

/// Reads the wake history with `pmset -g log` (no privileges needed).
public struct PmsetLogReader {
    public var runner: any CommandRunning

    public init(runner: any CommandRunning = ShellCommandRunner()) {
        self.runner = runner
    }

    public func recentWakes(scheduledWakes: [Date] = []) throws -> [WakeLogEvent] {
        let result = try runner.run("/usr/bin/pmset", arguments: ["-g", "log"])
        guard result.status == 0 else { throw PmsetError(status: result.status, output: result.output) }
        return WakeLogParser.parse(result.output, scheduledWakes: scheduledWakes)
    }
}
