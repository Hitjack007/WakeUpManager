import Darwin
import Foundation
import Testing
@testable import WakeUpCore

private struct FakeInspector: ProcessInspecting {
    var locationsByProcess: [Int32: [String]] = [:]
    var executables: [Int32: String] = [:]

    func locations(ofProcess pid: Int32) -> [String] { locationsByProcess[pid] ?? [] }
    func executablePath(ofProcess pid: Int32) -> String? { executables[pid] }
}

@Suite("Messages")
struct MessageTests {
    private func roundTrip(_ message: ClientMessage) throws -> ClientMessage {
        let data = try WakeUpJSON.makeCompactEncoder().encode(message)
        #expect(!data.contains(10), "a message must fit on one line")
        return try WakeUpJSON.makeDecoder().decode(ClientMessage.self, from: data)
    }

    @Test func aStatusFromAnOlderAgentHasNoBuildAndStillReads() throws {
        // Older agents never sent `agentBuild`. The app must still read their status, and see "unknown".
        let old = StatusReport(holdingAwake: false, clients: [], executions: [], recentHistory: [], openNotices: [])
        let data = try WakeUpJSON.makeCompactEncoder().encode(ServerMessage.report(old))
        #expect(!String(decoding: data, as: UTF8.self).contains("agentBuild"))
        let decoded = try WakeUpJSON.makeDecoder().decode(ServerMessage.self, from: data)
        #expect(decoded.status?.agentBuild == nil)
    }

    @Test func aBuildFingerprintFollowsTheFileContents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fingerprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("one".utf8).write(to: url)
        let first = try #require(BuildFingerprint.ofFile(at: url))
        #expect(BuildFingerprint.ofFile(at: url) == first)
        try Data("two".utf8).write(to: url)
        #expect(BuildFingerprint.ofFile(at: url) != first)
        #expect(BuildFingerprint.ofFile(at: url.appendingPathExtension("missing")) == nil)
    }

    @Test func aSubmitMessageRoundTrips() throws {
        let request = EngineFixtures.request(recurrence: Recurrence(frequency: .daily))
        let message = ClientMessage.submit(request)
        #expect(try roundTrip(message) == message)
    }

    @Test func aCompletionMessageRoundTrips() throws {
        let report = CompletionReport(
            executionId: UUID(), outcome: .partial, message: "usage limit",
            reschedule: .init(startAt: EngineFixtures.t("09:00"), estimatedDurationMinutes: 15))
        let message = ClientMessage.complete(report)
        #expect(try roundTrip(message) == message)
    }

    @Test func controlMessagesRoundTripAndAreMarkedAsControl() throws {
        let messages: [ClientMessage] = [
            .approveClient(path: "/Users/mark/Proj"),
            .denyClient(path: "/Users/mark/Proj"),
            .revokeClient(path: "/Users/mark/Proj"),
            .extend(executionId: UUID(), minutes: 30),
            .stop(executionId: UUID()),
            .resolveConflict(jobKey: "/Users/mark/Proj#job", allowBoth: true),
            .resolveNotice(id: UUID()),
            .setJobSettings(jobKey: "/Users/mark/Proj#job", settings: JobPowerSettings(minimumBatteryPercent: 50, allowHighOnBattery: true)),
            .removeJob(jobKey: "/Users/mark/Proj#job"),
        ]
        for message in messages {
            #expect(message.isControl)
            #expect(try roundTrip(message) == message)
        }
    }

    @Test func ordinaryMessagesAreNotControl() {
        let ordinary: [ClientMessage] = [
            .ping(), .status(), .submit(EngineFixtures.request()),
            .complete(CompletionReport(executionId: UUID(), outcome: .success)),
            .cancelJob(clientPath: "/Users/mark/Proj", jobId: "job"),
        ]
        for message in ordinary { #expect(!message.isControl) }
    }

    @Test func serverMessagesRoundTrip() throws {
        let status = StatusReport(holdingAwake: true, clients: [], executions: [], recentHistory: [], openNotices: [])
        let replies: [ServerMessage] = [.accepted(), .failure("no"), .report(status)]
        for reply in replies {
            let data = try WakeUpJSON.makeCompactEncoder().encode(reply)
            #expect(try WakeUpJSON.makeDecoder().decode(ServerMessage.self, from: data) == reply)
        }
    }
}

@Suite("Location verification")
struct LocationVerifierTests {
    private func verifier(_ locations: [Int32: [String]] = [:], executables: [Int32: String] = [:]) -> LocationVerifier {
        LocationVerifier(inspector: FakeInspector(locationsByProcess: locations, executables: executables))
    }

    @Test func aProcessInsideTheClaimedFolderIsVerified() {
        let verifier = verifier([10: ["/usr/local/bin/wakeup", "/Users/mark/Proj/scripts"]])
        #expect(verifier.verifies(claimedPath: "/Users/mark/Proj", peerProcess: 10))
    }

    @Test func aProcessElsewhereIsNotVerified() {
        let verifier = verifier([10: ["/usr/local/bin/wakeup", "/Users/mark/Other"]])
        #expect(!verifier.verifies(claimedPath: "/Users/mark/Proj", peerProcess: 10))
    }

    @Test func aFolderWithTheSamePrefixIsNotInside() {
        let verifier = verifier([10: ["/Users/mark/Proj2/run"]])
        #expect(!verifier.verifies(claimedPath: "/Users/mark/Proj", peerProcess: 10))
    }

    @Test func anAncestorInsideTheFolderCounts() {
        // The inspector lists the process and then its ancestors; the shell script's folder is last.
        let verifier = verifier([10: ["/usr/local/bin/wakeup", "/tmp", "/bin/sh", "/Users/mark/Proj/job.sh"]])
        #expect(verifier.verifies(claimedPath: "/Users/mark/Proj", peerProcess: 10))
    }

    @Test func anAppBundleIsVerifiedByItsExecutable() {
        let verifier = verifier([10: ["/Applications/Example.app/Contents/MacOS/Example"]])
        #expect(verifier.verifies(claimedPath: "/Applications/Example.app", peerProcess: 10))
    }

    @Test func tooBroadALocationCannotBeClaimed() {
        let verifier = verifier([10: ["/Users/mark/Proj"]])
        #expect(!verifier.verifies(claimedPath: "/", peerProcess: 10))
        #expect(!verifier.verifies(claimedPath: "/Users", peerProcess: 10))
        #expect(!verifier.verifies(claimedPath: "relative/path", peerProcess: 10))
    }

    @Test func anUnknownProcessIsNotVerified() {
        #expect(!verifier().verifies(claimedPath: "/Users/mark/Proj", peerProcess: 99))
    }

    @Test func aLocationHasOneCanonicalSpelling() {
        #expect(LocationVerifier.canonicalPath("/private/tmp/x") == "/tmp/x")
        #expect(LocationVerifier.canonicalPath("/tmp/x/") == "/tmp/x")
        #expect(LocationVerifier.canonicalPath("/tmp/a/../x") == "/tmp/x")
        #expect(LocationVerifier.canonicalPath("/Users/mark/Proj") == "/Users/mark/Proj")
    }

    @Test func thePrivatePrefixOfTemporaryFoldersDoesNotMatter() {
        let verifier = verifier([10: ["/private/var/folders/x/Proj/run"]])
        #expect(verifier.verifies(claimedPath: "/var/folders/x/Proj", peerProcess: 10))
    }

    @Test func onlyProgramsInsideTheTrustedAppMaySendControlMessages() {
        let app = "/Applications/WakeUpManager.app"
        let verifier = verifier(executables: [
            1: "\(app)/Contents/MacOS/WakeUpManager",
            2: "/usr/local/bin/wakeup",
            3: "/Applications/WakeUpManager.app.evil/run",
        ])
        #expect(verifier.isTrusted(peerProcess: 1, trustedPaths: [app]))
        #expect(!verifier.isTrusted(peerProcess: 2, trustedPaths: [app]))
        #expect(!verifier.isTrusted(peerProcess: 3, trustedPaths: [app]))
        #expect(!verifier.isTrusted(peerProcess: 99, trustedPaths: [app]))
        #expect(!verifier.isTrusted(peerProcess: 1, trustedPaths: []))
        #expect(!verifier.isTrusted(peerProcess: 1, trustedPaths: ["/"]))
    }
}

@Suite("Socket client")
struct SocketClientTests {
    private func shortSocketPath() -> String {
        "/tmp/wk-\(UUID().uuidString.prefix(8)).sock"
    }

    /// A minimal one-shot server: answers each connection with `reply` and records the line it received.
    private final class OneShotServer: @unchecked Sendable {
        let fd: Int32
        let path: String
        private let lock = NSLock()
        private var received: [Data] = []

        init(path: String, reply: ServerMessage) throws {
            self.path = path
            fd = try UnixSocket.listen(path: path)
            let fd = self.fd
            let thread = Thread { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { return }
                    if let line = try? UnixSocket.readLine(fd: client, maxBytes: 1_000_000) {
                        lock.lock(); received.append(line); lock.unlock()
                    }
                    var data = (try? WakeUpJSON.makeCompactEncoder().encode(reply)) ?? Data()
                    data.append(10)
                    try? UnixSocket.writeAll(fd: client, data: data)
                    close(client)
                }
            }
            thread.start()
        }

        var lines: [Data] {
            lock.lock(); defer { lock.unlock() }
            return received
        }

        func stop() {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    @Test func sendsAMessageAndReadsTheAnswer() throws {
        let path = shortSocketPath()
        let server = try OneShotServer(path: path, reply: .failure("nope"))
        defer { server.stop() }

        let reply = try SocketClient(path: path, timeout: 5).send(.cancelJob(clientPath: "/Users/mark/Proj", jobId: "job"))
        #expect(reply == .failure("nope"))

        let sent = try #require(server.lines.first)
        let decoded = try WakeUpJSON.makeDecoder().decode(ClientMessage.self, from: sent)
        #expect(decoded == .cancelJob(clientPath: "/Users/mark/Proj", jobId: "job"))
    }

    @Test func theSocketFileIsPrivateToTheUser() throws {
        let path = shortSocketPath()
        let server = try OneShotServer(path: path, reply: .accepted())
        defer { server.stop() }

        var info = stat()
        #expect(stat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test func connectingToNothingFailsClearly() {
        let path = shortSocketPath()
        #expect(throws: SocketError.self) {
            try SocketClient(path: path, timeout: 1).send(.ping())
        }
    }

    @Test func aTooLongPathIsRejected() {
        let path = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        #expect(throws: SocketError.pathTooLong(path)) {
            try SocketClient(path: path, timeout: 1).send(.ping())
        }
    }
}
