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
    /// What to do about wakes booked by other software. Off by default: turning it on cancels wakes that
    /// other projects book for themselves until they have been moved onto the scheduler.
    var auditMode = WakeAuditMode.off
    var auditInterval: TimeInterval = 30
    /// Book and cancel wakes through the root helper instead of `sudo pmset`. Needs `team`.
    var useHelper = false
    /// The signing team that the helper must belong to, so the agent only trusts the real helper.
    var team: String?
    /// Write the agent's own log to `agent.log` in the logs folder. launchd throws standard output away.
    var logToFile = false
}

let usage = """
Usage: wakeup-agent [--socket PATH] [--state PATH] [--logs DIR] [--trust PATH]... \
[--lead-minutes N] [--dry-run-wakes] [--notify] [--audit off|report|cancel] [--audit-interval SECONDS] \
[--helper --team TEAMID] [--log-to-file]
"""

/// When the agent runs from inside the app (`Foo.app/Contents/Helpers/wakeup-agent`), that app is trusted
/// to send control messages without being told where it is.
func enclosingAppPath(ofExecutable path: String) -> String? {
    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    var parts = url.pathComponents
    guard let index = parts.lastIndex(where: { $0.hasSuffix(".app") }) else { return nil }
    parts = Array(parts[...index])
    return NSString.path(withComponents: parts)
}

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
        case "--audit": guard let value = next(), let mode = WakeAuditMode(rawValue: value) else { return nil }; options.auditMode = mode
        case "--audit-interval": guard let value = next(), let seconds = TimeInterval(value), seconds > 0 else { return nil }; options.auditInterval = seconds
        case "--log-to-file": options.logToFile = true
        case "--helper": options.useHelper = true
        case "--team": guard let value = next(), !value.isEmpty else { return nil }; options.team = value
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

struct LoggingWakeBooker: WakeBooking, PowerEventCancelling {
    func book(at date: Date, owner: String) throws { log("(dry run) would book a wake at \(date.formatted())") }
    func cancel(at date: Date, owner: String) throws { log("(dry run) would cancel the wake at \(date.formatted())") }
    func cancelEvent(kind: String, at date: Date, owner: String) throws {
        log("(dry run) would cancel the \(kind) event owned by \"\(owner)\" at \(date.formatted())")
    }
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
    guard var options = parseOptions(Array(CommandLine.arguments.dropFirst())) else {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 64
    }
    if options.useHelper && options.team == nil {
        FileHandle.standardError.write(Data("--helper needs --team, so the agent only talks to the real helper.\n".utf8))
        return 64
    }
    if options.trusted.isEmpty, let executable = Bundle.main.executablePath, let app = enclosingAppPath(ofExecutable: executable) {
        options.trusted = [app]
    }
    if options.logToFile {
        try? FileManager.default.createDirectory(atPath: options.logsPath, withIntermediateDirectories: true)
        let logFile = options.logsPath + "/agent.log"
        freopen(logFile, "a", stdout)
        freopen(logFile, "a", stderr)
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
    // One booker does both jobs: booking the scheduler's wakes and cancelling other software's.
    let booker: any WakeBooking & PowerEventCancelling
    if options.dryRunWakes {
        booker = LoggingWakeBooker()
    } else if options.useHelper, let team = options.team {
        booker = XPCWakeBooker(helperRequirement: WakeHelperConstants.requirement(
            identifiers: [WakeHelperConstants.helperIdentifier], teamIdentifier: team))
    } else {
        booker = PmsetWakeBooker()
    }
    let wakes: any WakeBooking = booker
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
    let canceller: any PowerEventCancelling = booker
    let agent = SchedulerAgent(
        engine: engine,
        configuration: .init(
            socketPath: options.socketPath, trustedControlPaths: options.trusted,
            auditMode: options.auditMode, auditIntervalSeconds: options.auditInterval,
            scheduleReader: PmsetScheduleReader(), eventCanceller: canceller))

    do {
        try agent.start()
    } catch {
        log("Could not start: \(error.localizedDescription)")
        return 1
    }
    log("listening on \(options.socketPath)")
    log("state in \(options.statePath), job logs in \(options.logsPath)")
    if options.dryRunWakes { log("dry run: the Mac's wake schedule will not be changed") }
    switch options.auditMode {
    case .off: break
    case .report: log("wake audit: reporting wakes booked by other software, leaving them in place")
    case .cancel: log("wake audit: cancelling wakes booked by other software (never Apple's)")
    }
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
