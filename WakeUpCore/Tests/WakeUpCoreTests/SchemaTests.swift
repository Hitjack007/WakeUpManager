import Foundation
import Testing
@testable import WakeUpCore

@Suite("Schema")
struct SchemaTests {
    private let execJSON = """
    {
      "schemaVersion": 1,
      "requestId": "6F1C2D3E-0000-4000-8000-000000000001",
      "client": { "displayName": "ClaudeWriter", "path": "/Users/mark/ClaudeWriter" },
      "jobId": "claudewriter-nightshift",
      "name": "ClaudeWriter night shift",
      "schedule": { "start": "2026-11-12T01:13:00", "timeZone": "system" },
      "estimatedDurationMinutes": 60,
      "expectedCpuPercent": 20,
      "expectedGpuPercent": 0,
      "requires": ["network"],
      "launch": {
        "method": "exec",
        "executable": "/Users/mark/.local/bin/claude",
        "arguments": ["-p", "/book resume"],
        "workingDirectory": "/Users/mark/ClaudeWriter",
        "environment": { "PATH": "/usr/bin:/bin" }
      },
      "completion": { "reportedBy": "processExit" }
    }
    """

    private let appJSON = """
    {
      "schemaVersion": 1,
      "requestId": "6F1C2D3E-0000-4000-8000-000000000002",
      "client": { "displayName": "Example App", "path": "/Applications/Example.app" },
      "jobId": "example-app-sync",
      "name": "Example app sync",
      "schedule": {
        "start": "2026-11-12T06:00:00",
        "timeZone": "system",
        "repeat": { "frequency": "daily", "interval": 1 }
      },
      "estimatedDurationMinutes": 15,
      "expectedCpuPercent": 10,
      "expectedGpuPercent": 0,
      "launch": { "method": "app", "bundleId": "com.example.MyApp", "arguments": ["--sync"] },
      "completion": { "reportedBy": "client" }
    }
    """

    @Test func decodesAnExecRequest() throws {
        let request = try WakeUpJSON.makeDecoder().decode(WakeRequest.self, from: Data(execJSON.utf8))
        #expect(request.jobId == "claudewriter-nightshift")
        #expect(request.client.path == "/Users/mark/ClaudeWriter")
        #expect(request.requires == [.network])
        #expect(request.schedule.recurrence == nil)
        #expect(request.completion.reportedBy == .processExit)
        guard case .exec(let launch) = request.launch else {
            Issue.record("expected an exec launch")
            return
        }
        #expect(launch.executable == "/Users/mark/.local/bin/claude")
        #expect(launch.arguments == ["-p", "/book resume"])
        #expect(launch.environment["PATH"] == "/usr/bin:/bin")
    }

    @Test func decodesAnAppRequestWithARecurrenceAndDefaultsRequires() throws {
        let request = try WakeUpJSON.makeDecoder().decode(WakeRequest.self, from: Data(appJSON.utf8))
        #expect(request.requires.isEmpty)
        #expect(request.schedule.recurrence == Recurrence(frequency: .daily, interval: 1))
        #expect(request.launch == .app(AppLaunch(bundleId: "com.example.MyApp", arguments: ["--sync"])))
    }

    @Test(arguments: [0, 1])
    func roundTripsThroughJSON(_ index: Int) throws {
        let source = [execJSON, appJSON][index]
        let decoder = WakeUpJSON.makeDecoder()
        let original = try decoder.decode(WakeRequest.self, from: Data(source.utf8))
        let encoded = try WakeUpJSON.makeEncoder().encode(original)
        #expect(try decoder.decode(WakeRequest.self, from: encoded) == original)
    }

    @Test func launchIsEncodedWithAMethodDiscriminator() throws {
        let data = try WakeUpJSON.makeEncoder().encode(Launch.exec(ExecLaunch(executable: "/bin/echo")))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["method"] as? String == "exec")
        #expect(object["executable"] as? String == "/bin/echo")
    }

    @Test func recurrenceIsEncodedUnderTheKeyRepeat() throws {
        let schedule = Schedule(start: "2026-11-12T06:00:00", recurrence: Recurrence(frequency: .weekly))
        let data = try WakeUpJSON.makeEncoder().encode(schedule)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["repeat"] != nil)
        #expect(object["recurrence"] == nil)
    }

    @Test func unknownLaunchMethodIsRejected() {
        let json = #"{ "method": "teleport", "executable": "/bin/echo" }"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Launch.self, from: Data(json.utf8))
        }
    }

    @Test func responseAndCompletionReportRoundTrip() throws {
        let response = WakeResponse(
            requestId: UUID(),
            status: .authorised,
            reasonCode: .ok,
            message: "Scheduled.",
            plannedWakeAt: instant("2026-11-12T01:08:00+13:00"),
            plannedStartAt: instant("2026-11-12T01:13:00+13:00"))
        let report = CompletionReport(
            executionId: UUID(),
            outcome: .partial,
            message: "4 chunks done",
            reschedule: .init(startAt: instant("2026-11-12T06:13:00+13:00"), estimatedDurationMinutes: 60))

        let encoder = WakeUpJSON.makeEncoder()
        let decoder = WakeUpJSON.makeDecoder()
        #expect(try decoder.decode(WakeResponse.self, from: encoder.encode(response)) == response)
        #expect(try decoder.decode(CompletionReport.self, from: encoder.encode(report)) == report)
    }

    @Test func requestDerivesItsIntensityFromExpectedNumbers() throws {
        var request = try WakeUpJSON.makeDecoder().decode(WakeRequest.self, from: Data(execJSON.utf8))
        #expect(request.intensityLevel() == .low)
        request.expectedGpuPercent = 90
        #expect(request.intensityLevel() == .high)
    }
}
