import Foundation
import Testing
import WakeUpCore
@testable import WakeUpSystem

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [[String]] = []
    var result = CommandResult(status: 0, output: "")

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        commands.append([executable] + arguments)
        return result
    }
}

/// A helper and a booker joined by an in-process XPC listener, with no signing requirement (tests only).
private struct Link {
    let runner = RecordingRunner()
    let listener = NSXPCListener.anonymous()
    let delegate: WakeHelperListenerDelegate
    let booker: XPCWakeBooker

    init() {
        let service = WakeHelperService(runner: runner, timeZone: TimeZone(identifier: "Pacific/Auckland")!)
        delegate = WakeHelperListenerDelegate(service: service, requirement: nil)
        listener.delegate = delegate
        listener.resume()
        let endpoint = listener.endpoint
        booker = XPCWakeBooker(timeout: 5) { NSXPCConnection(listenerEndpoint: endpoint) }
    }
}

private let soon = Date().addingTimeInterval(3_600)

@Suite("Wake helper", .serialized)
struct WakeHelperTests {
    @Test func booksAWakeAsRootWithoutSudo() throws {
        let link = Link()
        try link.booker.book(at: soon, owner: "com.wakeupmanager.scheduler")

        let command = try #require(link.runner.commands.first)
        #expect(command[0] == "/usr/bin/pmset")
        #expect(Array(command[1...2]) == ["schedule", "wake"])
        #expect(command.last == "com.wakeupmanager.scheduler")
    }

    @Test func cancelsAnyWakeKindButNotOtherEvents() throws {
        let link = Link()
        try link.booker.cancelEvent(kind: "wakepoweron", at: soon, owner: "nightshift")
        #expect(link.runner.commands.first?.contains("wakepoweron") == true)

        #expect(throws: XPCWakeBooker.HelperError.self) {
            try link.booker.cancelEvent(kind: "shutdown", at: soon, owner: "nightshift")
        }
        #expect(link.runner.commands.count == 1)
    }

    @Test func neverTouchesEventsOwnedByMacOS() throws {
        let link = Link()
        #expect(throws: XPCWakeBooker.HelperError.self) {
            try link.booker.cancelEvent(kind: "wake", at: soon, owner: "com.apple.alarm.user-invisible-x")
        }
        #expect(throws: XPCWakeBooker.HelperError.self) {
            try link.booker.book(at: soon, owner: "com.apple.something")
        }
        #expect(link.runner.commands.isEmpty)
    }

    @Test func refusesBadOwnersAndTimes() throws {
        let link = Link()
        for owner in ["", "-flag", "line\nbreak", String(repeating: "x", count: 500)] {
            #expect(throws: XPCWakeBooker.HelperError.self) { try link.booker.book(at: soon, owner: owner) }
        }
        #expect(throws: XPCWakeBooker.HelperError.self) {
            try link.booker.book(at: Date().addingTimeInterval(-60), owner: "ok")
        }
        #expect(throws: XPCWakeBooker.HelperError.self) {
            try link.booker.book(at: Date().addingTimeInterval(1000 * 86_400), owner: "ok")
        }
        #expect(link.runner.commands.isEmpty)
    }

    @Test func passesPmsetFailuresBack() throws {
        let link = Link()
        link.runner.result = CommandResult(status: 1, output: "Error in scheduling operation")
        let error = #expect(throws: XPCWakeBooker.HelperError.self) {
            try link.booker.book(at: soon, owner: "ok")
        }
        #expect(error?.errorDescription?.contains("Error in scheduling operation") == true)
    }

    @Test func reportsItsVersion() throws {
        let link = Link()
        #expect(try link.booker.helperVersion() == WakeHelperConstants.version)
    }

    @Test func buildsASigningRequirement() {
        let text = WakeHelperConstants.requirement(identifiers: ["a.b", "c.d"], teamIdentifier: "TEAM123456")
        #expect(text == "anchor apple generic and (identifier \"a.b\" or identifier \"c.d\") and certificate leaf[subject.OU] = \"TEAM123456\"")
    }
}
