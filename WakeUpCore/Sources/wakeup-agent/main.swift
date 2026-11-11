import Darwin
import Dispatch
import Foundation
import WakeUpCore
import WakeUpSystem

// The WakeUp Manager scheduler agent: runs the scheduling engine, listens on a Unix socket for requests
// from the `wakeup` tool and from apps, books wakes, holds the Mac awake while jobs run, and starts them.
//
//   wakeup-agent [--socket PATH] [--state PATH] [--logs DIR] [--trust PATH]... [--dry-run-wakes] [--notify]

struct Options {
    var socketPath = WakeUpPaths.socketPath
    var statePath = WakeUpPaths.stateURL.path
    var logsPath = WakeUpPaths.logsDirectory.path
    /// Programs inside these locations may send control messages. In production that is the app; while
    /// developing it can be the `wakeup` tool.
    var trusted: [String] = []
    /// Say what would be booked instead of changing the Mac's wake schedule.
    var dryRunWakes = false
    var notify = false
    var leadMinutes: Int?
}

let usage = """
Usage: wakeup-agent [--socket PATH] [--state PATH] [--logs DIR] [--trust PATH]... \
[--lead-minutes N] [--dry-run-wakes] [--notify]
"""

func parseOptions(_ arguments: [String]) -> Options? {
    var options = Options()
    var index = 0
    func next() -> String? {
        index += 1
        return index < arguments.count ? arguments[index] : nil
    }
    while index < arguments.count {
        switch arguments[index] {
        case "--socket": guard let value = next() else { return nil }; options.socketPath = value
        case "--state": guard let value = next() else { return nil }; options.statePath = value
        case "--logs": guard let value = next() else { return nil }; options.logsPath = value
        case "--trust": guard let value = next() else { return nil }; options.trusted.append(value)
        case "--lead-minutes": guard let value = next(), let minutes = Int(value) else { return nil }; options.leadMinutes = minutes
        case "--dry-run-wakes": options.dryRunWakes = true
        case "--notify": options.notify = true
        default: return nil
        }
        index += 1
    }
    return options
}

func log(_ text: String) {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(formatter.string(from: Date()))  \(text)")
}

struct LoggingWakeBooker: WakeBooking {
    func book(at date: Date, owner: String) throws { log("(dry run) would book a wake at \(date.formatted())") }
    func cancel(at date: Date, owner: String) throws { log("(dry run) would cancel the wake at \(date.formatted())") }
}

func showNotification(_ notice: Notice) {
    func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    let script = "display notification \"\(escaped(notice.detail))\" with title \"WakeUp Manager\" subtitle \"\(escaped(notice.title))\""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try? process.run()
}

/// Keeps the agent and the awake hold alive for the signal handlers.
final class Runtime: @unchecked Sendable {
    let agent: SchedulerAgent
    let awake: PowerAssertionHolder

    init(agent: SchedulerAgent, awake: PowerAssertionHolder) {
        self.agent = agent
        self.awake = awake
    }

    func shutDown() {
        log("stopping")
        agent.stop()
        awake.release()
    }
}

func runAgent() -> Int32 {
    guard let options = parseOptions(Array(CommandLine.arguments.dropFirst())) else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 64
    }
    setvbuf(stdout, nil, _IOLBF, 0)

    do {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: options.socketPath).deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
        log("Could not create the folder for the socket: \(error.localizedDescription)")
        return 1
    }

    let store = JSONFileStateStore(url: URL(fileURLWithPath: options.statePath))
    let state: EngineState
    do {
        state = try store.load() ?? EngineState()
    } catch {
        log("Could not read the saved state (\(error.localizedDescription)); starting empty.")
        state = EngineState()
    }

    let awake = PowerAssertionHolder()
    let launcher = ProcessJobLauncher(socketPath: options.socketPath, logDirectory: URL(fileURLWithPath: options.logsPath))
    let wakes: any WakeBooking = options.dryRunWakes ? LoggingWakeBooker() : PmsetWakeBooker()
    let notify = options.notify
    let notifier = ClosureNotifier { notice in
        log("NOTICE \(notice.kind.rawValue): \(notice.title). \(notice.detail)")
        if notify { showNotification(notice) }
    }

    var settings = EngineSettings()
    if let minutes = options.leadMinutes { settings.leadMinutes = minutes }

    let engine = SchedulerEngine(
        state: state, settings: settings,
        ports: EnginePorts(
            wakes: wakes, awake: awake, launcher: launcher, power: BatteryPowerSensor(),
            notifier: notifier, store: store))
    let agent = SchedulerAgent(
        engine: engine,
        configuration: .init(socketPath: options.socketPath, trustedControlPaths: options.trusted))

    do {
        try agent.start()
    } catch {
        log("Could not start: \(error.localizedDescription)")
        return 1
    }
    log("listening on \(options.socketPath)")
    log("state in \(options.statePath), job logs in \(options.logsPath)")
    if options.dryRunWakes { log("dry run: the Mac's wake schedule will not be changed") }
    if !options.trusted.isEmpty { log("control messages are accepted from: \(options.trusted.joined(separator: ", "))") }

    let runtime = Runtime(agent: agent, awake: awake)
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            runtime.shutDown()
            exit(0)
        }
        source.resume()
        return source
    }
    withExtendedLifetime(sources) { dispatchMain() }
}

exit(runAgent())
