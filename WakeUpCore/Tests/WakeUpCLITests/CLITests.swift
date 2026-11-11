import Foundation
import Testing
import WakeUpCore
@testable import WakeUpCLI

/// A scheduler that records what it is sent and answers with canned replies.
private final class FakeClient: SchedulerClient {
    var sent: [ClientMessage] = []
    var reply = ServerMessage.accepted()
    var error: (any Error)?

    func send(_ message: ClientMessage) throws -> ServerMessage {
        sent.append(message)
        if let error { throw error }
        return reply
    }
}

private struct Output {
    var standard = ""
    var errors = ""
}

private func run(
    _ arguments: [String], client: FakeClient = FakeClient(), environment: [String: String] = [:],
    directory: String = "/Users/mark/Proj"
) -> (code: Int32, out: Output, client: FakeClient) {
    var output = Output()
    let cli = CLI(
        client: client, environment: environment, currentDirectory: directory,
        write: { output.standard += $0 }, writeError: { output.errors += $0 })
    let code = cli.run(arguments)
    return (code, output, client)
}

private let basicRequest = [
    "request", "--name", "Nightly Backup", "--at", "2026-11-12T03:00", "--estimate", "45",
    "--exec", "/usr/local/bin/python3", "--", "/Users/mark/Proj/backup.py", "--full",
]

private func authorised(_ status: WakeResponse.Status = .authorised) -> ServerMessage {
    .answer(WakeResponse(requestId: UUID(), status: status, reasonCode: .ok, message: "Scheduled.",
                         plannedWakeAt: Date(timeIntervalSince1970: 1_800_000_000),
                         plannedStartAt: Date(timeIntervalSince1970: 1_800_000_300)))
}

@Suite("Building requests")
struct RequestBuildingTests {
    @Test func buildsAnExecRequestFromOptionsAndPassthroughArguments() throws {
        let client = FakeClient()
        client.reply = authorised()
        let result = run(basicRequest + [], client: client)
        #expect(result.code == 0)

        let request = try #require(client.sent.first?.request)
        #expect(request.name == "Nightly Backup")
        #expect(request.jobId == "nightly-backup")
        #expect(request.schedule == Schedule(start: "2026-11-12T03:00", timeZone: "system"))
        #expect(request.estimatedDurationMinutes == 45)
        #expect(request.expectedCpuPercent == 10)
        #expect(request.expectedGpuPercent == 0)
        #expect(request.completion.reportedBy == .processExit)
        #expect(request.launch == .exec(ExecLaunch(executable: "/usr/local/bin/python3", arguments: ["/Users/mark/Proj/backup.py", "--full"])))
    }

    @Test func theClientDefaultsToTheCurrentDirectory() throws {
        let client = FakeClient()
        client.reply = authorised()
        _ = run(basicRequest, client: client, directory: "/Users/mark/ClaudeWriter")
        let request = try #require(client.sent.first?.request)
        #expect(request.client == ClientInfo(displayName: "ClaudeWriter", path: "/Users/mark/ClaudeWriter"))
    }

    @Test func theClientCanBeNamedExplicitly() throws {
        let client = FakeClient()
        client.reply = authorised()
        let options = basicRequest.prefix(while: { $0 != "--" }) + ["--client-path", "/Users/mark/Other", "--client-name", "Other Thing"]
        _ = run(Array(options), client: client)
        let request = try #require(client.sent.last?.request)
        #expect(request.client == ClientInfo(displayName: "Other Thing", path: "/Users/mark/Other"))
    }

    @Test func buildsARecurringRequestWithWeekdays() throws {
        let client = FakeClient()
        client.reply = authorised()
        let arguments = [
            "request", "--name", "Weekly", "--at", "2026-11-12T06:00", "--estimate", "20", "--app", "com.example.App",
            "--repeat", "weekly", "--days", "mon,Thursday", "--every", "2", "--until", "2027-01-01T00:00",
            "--cpu", "40", "--gpu", "85", "--requires", "network",
        ]
        #expect(run(arguments, client: client).code == 0)

        let request = try #require(client.sent.first?.request)
        #expect(request.schedule.recurrence == Recurrence(frequency: .weekly, interval: 2, daysOfWeek: [.monday, .thursday], until: "2027-01-01T00:00"))
        #expect(request.expectedCpuPercent == 40)
        #expect(request.expectedGpuPercent == 85)
        #expect(request.requires == [.network])
        #expect(request.launch == .app(AppLaunch(bundleId: "com.example.App")))
        #expect(request.completion.reportedBy == .client)   // apps report themselves by default
    }

    @Test func passesEnvironmentAndWorkingDirectory() throws {
        let client = FakeClient()
        client.reply = authorised()
        let arguments = basicRequest.prefix(while: { $0 != "--" }) + [
            "--cwd", "/Users/mark/Proj", "--env", "PATH=/opt/homebrew/bin:/usr/bin", "--env", "MODE=night", "--reported-by", "client",
        ]
        #expect(run(Array(arguments), client: client).code == 0)
        let request = try #require(client.sent.first?.request)
        guard case .exec(let launch) = request.launch else { Issue.record("expected exec"); return }
        #expect(launch.workingDirectory == "/Users/mark/Proj")
        #expect(launch.environment == ["PATH": "/opt/homebrew/bin:/usr/bin", "MODE": "night"])
        #expect(request.completion.reportedBy == .client)
    }

    @Test func readsAWholeRequestFromAFile() throws {
        let request = WakeRequest(
            client: ClientInfo(displayName: "From File", path: "/Users/mark/Proj"), jobId: "from-file", name: "From file",
            schedule: Schedule(start: "2026-11-12T07:00"), estimatedDurationMinutes: 10, expectedCpuPercent: 5,
            expectedGpuPercent: 0, launch: .exec(ExecLaunch(executable: "/bin/echo")), completion: CompletionSpec(reportedBy: .processExit))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("request-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try WakeUpJSON.makeEncoder().encode(request).write(to: url)

        let client = FakeClient()
        client.reply = authorised()
        #expect(run(["request", "--file", url.path], client: client).code == 0)
        #expect(client.sent.first?.request == request)
    }

    @Test(arguments: [
        ["request", "--at", "2026-11-12T03:00", "--estimate", "45", "--exec", "/bin/echo"],                    // no name
        ["request", "--name", "x", "--estimate", "45", "--exec", "/bin/echo"],                                  // no time
        ["request", "--name", "x", "--at", "2026-11-12T03:00", "--exec", "/bin/echo"],                          // no estimate
        ["request", "--name", "x", "--at", "2026-11-12T03:00", "--estimate", "45"],                             // no launch
        ["request", "--name", "x", "--at", "2026-11-12T03:00", "--estimate", "soon", "--exec", "/bin/echo"],    // bad number
        ["request", "--name", "x", "--at", "2026-11-12T03:00", "--estimate", "5", "--exec", "/bin/echo", "--repeat", "hourly"],
        ["request", "--name", "x", "--at", "2026-11-12T03:00", "--estimate", "5", "--exec", "/bin/echo", "--env", "NOEQUALS"],
        ["request", "--name", "x", "--at", "2026-11-12T03:00", "--estimate", "5", "--exec", "/bin/echo", "--reported-by", "magic"],
        ["frobnicate"],
        ["admin"],
    ])
    func usageErrorsExitWith64AndSendNothing(_ arguments: [String]) {
        let result = run(arguments)
        #expect(result.code == 64)
        #expect(result.client.sent.isEmpty)
        #expect(!result.out.errors.isEmpty)
    }
}

@Suite("Exit codes and output")
struct OutputTests {
    @Test(arguments: [
        (WakeResponse.Status.authorised, Int32(0)),
        (.rejected, 1),
        (.pendingApproval, 10),
        (.conflict, 11),
    ])
    func eachAnswerHasItsOwnExitCode(_ status: WakeResponse.Status, _ code: Int32) {
        let client = FakeClient()
        client.reply = authorised(status)
        let result = run(basicRequest, client: client)
        #expect(result.code == code)
        #expect(result.out.standard.hasPrefix(status.rawValue))
    }

    @Test func printsTheResponseAsJSONOnRequest() throws {
        let client = FakeClient()
        client.reply = authorised()
        // Options must come before the bare `--`; after it everything belongs to the job.
        let result = run(Array(basicRequest.prefix(while: { $0 != "--" })) + ["--json"], client: client)
        let response = try WakeUpJSON.makeDecoder().decode(WakeResponse.self, from: Data(result.out.standard.utf8))
        #expect(response.status == .authorised)
    }

    @Test func aRefusalFromTheSchedulerExitsWith3() {
        let client = FakeClient()
        client.reply = .failure("Could not confirm that this request comes from /Users/mark/Proj.")
        let result = run(basicRequest, client: client)
        #expect(result.code == 3)
        #expect(result.out.errors.contains("Could not confirm"))
    }

    @Test func anUnreachableSchedulerExitsWith2() {
        let client = FakeClient()
        client.error = SocketError.system("connect to /tmp/x.sock", ENOENT)
        let result = run(basicRequest, client: client)
        #expect(result.code == 2)
        #expect(result.out.errors.contains("could not reach the scheduler"))
    }

    @Test func helpPrintsTheUsage() {
        let result = run(["help"])
        #expect(result.code == 0)
        #expect(result.out.standard.contains("wakeup request"))
        #expect(result.client.sent.isEmpty)
    }
}

@Suite("Other commands")
struct OtherCommandTests {
    @Test func doneUsesTheExecutionIdFromTheEnvironment() throws {
        let id = UUID()
        let result = run(["done", "--message", "all good"], environment: ["WAKEUP_EXECUTION_ID": id.uuidString])
        #expect(result.code == 0)
        let report = try #require(result.client.sent.first?.report)
        #expect(report == CompletionReport(executionId: id, outcome: .success, message: "all good"))
    }

    @Test func doneCanFailAndRescheduleAtAnInstant() throws {
        let id = UUID()
        let result = run(
            ["done", "--status", "partial", "--reschedule-at", "2026-11-13T07:00:00+13:00", "--reschedule-minutes", "30"],
            environment: ["WAKEUP_EXECUTION_ID": id.uuidString])
        #expect(result.code == 0)
        let report = try #require(result.client.sent.first?.report)
        #expect(report.outcome == .partial)
        #expect(report.reschedule?.estimatedDurationMinutes == 30)
        #expect(report.reschedule?.startAt == Date(timeIntervalSince1970: 1_794_506_400))
    }

    @Test func doneWithoutAnExecutionIdIsAUsageError() {
        let result = run(["done"])
        #expect(result.code == 64)
        #expect(result.out.errors.contains("execution id"))
        #expect(result.client.sent.isEmpty)
    }

    @Test func cancelSendsTheClientAndJob() {
        let result = run(["cancel", "--job-id", "nightly"], directory: "/Users/mark/Proj")
        #expect(result.code == 0)
        #expect(result.client.sent == [.cancelJob(clientPath: "/Users/mark/Proj", jobId: "nightly")])
    }

    @Test func statusSummarisesTheScheduler() {
        let client = FakeClient()
        client.reply = .report(StatusReport(
            holdingAwake: true,
            clients: [ClientRecord(path: "/Users/mark/Proj", displayName: "Proj", status: .approved, firstSeen: .now, lastRequest: .now)],
            executions: [], recentHistory: [],
            openNotices: [Notice(kind: .overrun, title: "Backup is still going", detail: "Past its estimate.", date: .now)]))
        let result = run(["status"], client: client)
        #expect(result.code == 0)
        #expect(result.out.standard.contains("Holding the Mac awake: yes"))
        #expect(result.out.standard.contains("Proj (approved)"))
        #expect(result.out.standard.contains("Backup is still going"))
    }

    @Test func adminCommandsSendControlMessages() {
        let id = UUID()
        #expect(run(["admin", "approve", "--path", "/Users/mark/Proj"]).client.sent == [.approveClient(path: "/Users/mark/Proj")])
        #expect(run(["admin", "revoke", "--path", "/Users/mark/Proj"]).client.sent == [.revokeClient(path: "/Users/mark/Proj")])
        #expect(run(["admin", "stop", "--execution-id", id.uuidString]).client.sent == [.stop(executionId: id)])
        #expect(run(["admin", "extend", "--execution-id", id.uuidString, "--minutes", "30"]).client.sent == [.extend(executionId: id, minutes: 30)])
    }
}

@Suite("Argument parsing")
struct ArgumentParsingTests {
    @Test func separatesOptionsFlagsAndPassthrough() throws {
        let parsed = try ParsedArguments.parse(["request", "--name", "A", "--env=X=1", "--env", "Y=2", "--json", "--", "--not-an-option", "x"])
        #expect(parsed.positionals == ["request"])
        #expect(parsed.value("name") == "A")
        #expect(parsed.values("env") == ["X=1", "Y=2"])
        #expect(parsed.flags == ["json"])
        #expect(parsed.passthrough == ["--not-an-option", "x"])
    }

    @Test func anOptionWithoutAValueIsAnError() {
        #expect(throws: UsageError("--name needs a value.")) {
            try ParsedArguments.parse(["request", "--name"])
        }
    }

    @Test func slugsAreTidy() {
        #expect(RequestBuilder.slug("Nightly Backup!") == "nightly-backup")
        #expect(RequestBuilder.slug("  ") == "job")
    }
}
