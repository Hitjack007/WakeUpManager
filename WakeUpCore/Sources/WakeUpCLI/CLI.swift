import Foundation
import WakeUpCore

/// The `wakeup` command. It builds a message, sends it to the scheduler agent, and prints the answer.
///
/// Exit codes: 0 done or authorised, 1 rejected, 2 the scheduler could not be reached, 3 the scheduler
/// refused the message, 10 waiting for the user to approve the client, 11 an overlap waiting for the
/// user's decision, 64 the command was used wrongly.
public final class CLI {
    public static let usage = """
    wakeup: ask the WakeUp Manager scheduler to wake this Mac for a job.

    Usage:
      wakeup request --name NAME --at 2026-11-12T07:00 --estimate MINUTES --exec PATH [-- ARGS...]
                     [--job-id ID] [--tz system|ZONE] [--repeat daily|weekly] [--every N]
                     [--days mon,thu] [--until DATETIME] [--cpu PERCENT] [--gpu PERCENT]
                     [--client-path PATH] [--client-name NAME] [--cwd DIR] [--env NAME=value]
                     [--reported-by processExit|client|appQuit] [--requires network] [--json]
      wakeup request --name NAME --at DATETIME --estimate MINUTES --app BUNDLE-ID [--url URL] [-- ARGS...]
      wakeup request --file request.json
      wakeup done [--status success|failure|partial] [--message TEXT]
                  [--reschedule-at 2026-11-13T07:00:00+13:00 [--reschedule-minutes N]]
                  [--execution-id ID]
      wakeup cancel --job-id ID [--client-path PATH]
      wakeup status [--json]
      wakeup ping

    Times are local wall-clock times (a job at 07:00 stays at 07:00 when daylight saving changes).
    The client is the project folder or app that owns the job; it defaults to the current directory, and
    the scheduler checks that this command really is running from inside it.

    Inside a job started by the scheduler, `wakeup done` finds the execution id and socket by itself.
    """

    private let client: any SchedulerClient
    private let environment: [String: String]
    private let currentDirectory: String
    private let write: (String) -> Void
    private let writeError: (String) -> Void

    public init(
        client: any SchedulerClient,
        environment: [String: String],
        currentDirectory: String,
        write: @escaping (String) -> Void,
        writeError: @escaping (String) -> Void
    ) {
        self.client = client
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.write = write
        self.writeError = writeError
    }

    public func run(_ arguments: [String]) -> Int32 {
        do {
            let parsed = try ParsedArguments.parse(arguments)
            guard let command = parsed.positionals.first else {
                write(Self.usage + "\n")
                return 64
            }
            if command == "help" || parsed.flags.contains("help") {
                write(Self.usage + "\n")
                return 0
            }
            switch command {
            case "request": return try request(parsed)
            case "done": return try done(parsed)
            case "cancel": return try cancel(parsed)
            case "status": return try status(parsed)
            case "ping": return try ping()
            case "admin": return try admin(parsed)
            default: throw UsageError("Unknown command \"\(command)\". Try: wakeup help")
            }
        } catch let error as UsageError {
            writeError("wakeup: \(error.message)\n")
            return 64
        } catch {
            writeError("wakeup: could not reach the scheduler: \(error.localizedDescription)\n")
            return 2
        }
    }

    // MARK: Commands

    private func request(_ parsed: ParsedArguments) throws -> Int32 {
        let request = try RequestBuilder.build(from: parsed, currentDirectory: currentDirectory)
        let reply = try client.send(.submit(request))
        guard reply.ok, let response = reply.response else { return refused(reply) }

        if parsed.flags.contains("json") {
            write(try json(response) + "\n")
        } else {
            write(describe(response) + "\n")
        }
        switch response.status {
        case .authorised: return 0
        case .rejected: return 1
        case .pendingApproval: return 10
        case .conflict: return 11
        }
    }

    private func done(_ parsed: ParsedArguments) throws -> Int32 {
        guard let idText = parsed.value("execution-id") ?? environment["WAKEUP_EXECUTION_ID"] else {
            throw UsageError("No execution id. Run this inside a job started by the scheduler, or pass --execution-id.")
        }
        guard let id = UUID(uuidString: idText) else { throw UsageError("\"\(idText)\" is not a valid execution id.") }

        let outcomeText = parsed.value("status") ?? "success"
        guard let outcome = CompletionReport.Outcome(rawValue: outcomeText) else {
            throw UsageError("--status must be success, failure or partial, not \"\(outcomeText)\".")
        }

        var reschedule: CompletionReport.Reschedule?
        if let at = parsed.value("reschedule-at") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: at) else {
                throw UsageError("--reschedule-at must look like 2026-11-13T07:00:00+13:00, not \"\(at)\".")
            }
            reschedule = .init(startAt: date, estimatedDurationMinutes: try parsed.integer("reschedule-minutes") ?? 60)
        }

        let report = CompletionReport(executionId: id, outcome: outcome, message: parsed.value("message"), reschedule: reschedule)
        let reply = try client.send(.complete(report))
        guard reply.ok else { return refused(reply) }
        write("Reported \(outcome.rawValue).\n")
        return 0
    }

    private func cancel(_ parsed: ParsedArguments) throws -> Int32 {
        let jobId = try parsed.required("job-id")
        let path = parsed.value("client-path") ?? currentDirectory
        let reply = try client.send(.cancelJob(clientPath: path, jobId: jobId))
        guard reply.ok else { return refused(reply) }
        write("Cancelled \(jobId).\n")
        return 0
    }

    private func status(_ parsed: ParsedArguments) throws -> Int32 {
        let reply = try client.send(.status())
        guard reply.ok, let status = reply.status else { return refused(reply) }
        if parsed.flags.contains("json") {
            write(try json(status) + "\n")
        } else {
            write(describe(status))
        }
        return 0
    }

    private func ping() throws -> Int32 {
        let reply = try client.send(.ping())
        guard reply.ok else { return refused(reply) }
        write("The scheduler is running.\n")
        return 0
    }

    /// Control commands. The scheduler only accepts these from the WakeUp Manager app (or, while
    /// developing, from a program it has been told to trust).
    private func admin(_ parsed: ParsedArguments) throws -> Int32 {
        guard parsed.positionals.count >= 2 else {
            throw UsageError("admin needs a subcommand: approve, deny, revoke, extend, stop.")
        }
        let message: ClientMessage
        switch parsed.positionals[1] {
        case "approve": message = .approveClient(path: try parsed.required("path"))
        case "deny": message = .denyClient(path: try parsed.required("path"))
        case "revoke": message = .revokeClient(path: try parsed.required("path"))
        case "stop": message = .stop(executionId: try executionId(parsed))
        case "extend":
            guard let minutes = try parsed.integer("minutes") else { throw UsageError("--minutes is required.") }
            message = .extend(executionId: try executionId(parsed), minutes: minutes)
        default:
            throw UsageError("Unknown admin command \"\(parsed.positionals[1])\".")
        }
        let reply = try client.send(message)
        guard reply.ok else { return refused(reply) }
        write("Done.\n")
        return 0
    }

    private func executionId(_ parsed: ParsedArguments) throws -> UUID {
        let text = try parsed.required("execution-id")
        guard let id = UUID(uuidString: text) else { throw UsageError("\"\(text)\" is not a valid execution id.") }
        return id
    }

    // MARK: Output

    private func refused(_ reply: ServerMessage) -> Int32 {
        writeError("wakeup: \(reply.error ?? "the scheduler refused that.")\n")
        return 3
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try WakeUpJSON.makeEncoder().encode(value), as: UTF8.self)
    }

    private func format(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private func describe(_ response: WakeResponse) -> String {
        var text = "\(response.status.rawValue): \(response.message)"
        if let start = response.plannedStartAt {
            text += " Starts \(format(start))"
            if let wake = response.plannedWakeAt { text += ", the Mac wakes at \(format(wake))" }
            text += "."
        }
        for conflict in response.conflicts {
            text += "\n  overlaps \(conflict.jobId) at \(format(conflict.startAt))"
        }
        return text
    }

    private func describe(_ status: StatusReport) -> String {
        var lines = ["Holding the Mac awake: \(status.holdingAwake ? "yes" : "no")"]

        lines.append("\nClients:")
        if status.clients.isEmpty { lines.append("  none") }
        for client in status.clients {
            lines.append("  \(client.displayName) (\(client.status.rawValue))  \(client.path)")
        }

        lines.append("\nScheduled and running:")
        if status.executions.isEmpty { lines.append("  nothing") }
        for execution in status.executions {
            lines.append("  \(format(execution.plannedStart))  \(execution.jobName)  [\(execution.state.rawValue)]  \(execution.clientName)")
        }

        lines.append("\nRecent:")
        if status.recentHistory.isEmpty { lines.append("  nothing yet") }
        for execution in status.recentHistory.prefix(10) {
            let note = execution.message.map { " - \($0)" } ?? ""
            lines.append("  \(format(execution.plannedStart))  \(execution.jobName)  [\(execution.state.rawValue)]\(note)")
        }

        if !status.openNotices.isEmpty {
            lines.append("\nNeeds attention:")
            for notice in status.openNotices { lines.append("  \(notice.title): \(notice.detail)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
