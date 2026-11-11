import Foundation
import Testing
import WakeUpCore
@testable import WakeUpSystem

private func instant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: iso) else { fatalError("bad test date \(iso)") }
    return date
}

/// Records the commands it is asked to run and returns a canned result.
private final class RecordingRunner: CommandRunning {
    var commands: [(executable: String, arguments: [String])] = []
    var result = CommandResult(status: 0, output: "")

    func run(_ executable: String, arguments: [String]) throws -> CommandResult {
        commands.append((executable, arguments))
        return result
    }
}

@Suite("Booking wakes with pmset")
struct PmsetWakeBookerTests {
    private let auckland = TimeZone(identifier: "Pacific/Auckland")!
    private let owner = "com.wakeupmanager.scheduler"

    @Test func booksALocalTimeWakeWithTheOwnerTag() throws {
        let runner = RecordingRunner()
        let booker = PmsetWakeBooker(runner: runner, timeZone: auckland)
        try booker.book(at: instant("2026-11-12T06:55:00+13:00"), owner: owner)

        #expect(runner.commands.count == 1)
        #expect(runner.commands[0].executable == "/usr/bin/sudo")
        #expect(runner.commands[0].arguments == [
            "-n", "/usr/bin/pmset", "schedule", "wake", "11/12/26 06:55:00", owner,
        ])
    }

    @Test func cancelsWithTheSameTimeAndOwner() throws {
        let runner = RecordingRunner()
        let booker = PmsetWakeBooker(runner: runner, timeZone: auckland)
        try booker.cancel(at: instant("2026-11-12T06:55:00+13:00"), owner: owner)

        #expect(runner.commands[0].arguments == [
            "-n", "/usr/bin/pmset", "schedule", "cancel", "wake", "11/12/26 06:55:00", owner,
        ])
    }

    @Test func canRunPmsetDirectlyWithoutSudo() throws {
        let runner = RecordingRunner()
        let booker = PmsetWakeBooker(runner: runner, useSudo: false, timeZone: auckland)
        try booker.book(at: instant("2026-11-12T06:55:00+13:00"), owner: owner)

        #expect(runner.commands[0].executable == "/usr/bin/pmset")
        #expect(runner.commands[0].arguments.first == "schedule")
    }

    @Test func theTimeIsWrittenInTheGivenZoneAcrossDaylightSaving() throws {
        let runner = RecordingRunner()
        let booker = PmsetWakeBooker(runner: runner, timeZone: auckland)
        // 07:00 NZST before the change and 07:00 NZDT after: the same wall-clock text.
        try booker.book(at: instant("2026-09-26T07:00:00+12:00"), owner: owner)
        try booker.book(at: instant("2026-09-27T07:00:00+13:00"), owner: owner)

        #expect(runner.commands[0].arguments.contains("09/26/26 07:00:00"))
        #expect(runner.commands[1].arguments.contains("09/27/26 07:00:00"))
    }

    @Test func aFailureCarriesPmsetsMessage() {
        let runner = RecordingRunner()
        runner.result = CommandResult(status: 1, output: "sudo: a password is required\n")
        let booker = PmsetWakeBooker(runner: runner, timeZone: auckland)

        #expect(throws: PmsetError(status: 1, output: "sudo: a password is required\n")) {
            try booker.book(at: instant("2026-11-12T06:55:00+13:00"), owner: owner)
        }
    }
}

@Suite("Battery sensor")
struct BatteryPowerSensorTests {
    @Test func readsAValidPowerState() {
        let state = BatteryPowerSensor().current()
        if let percent = state.batteryPercent {
            #expect((0...100).contains(percent))
        }
        // A Mac without a battery can only be on mains power.
        if state.batteryPercent == nil {
            #expect(state.source == .ac)
        }
    }
}

@Suite("Power assertions")
struct PowerAssertionHolderTests {
    private func assertionsOutput() throws -> String {
        try ShellCommandRunner().run("/usr/bin/pmset", arguments: ["-g", "assertions"]).output
    }

    @Test func holdingShowsUpInPmsetAndReleasingRemovesIt() throws {
        let holder = PowerAssertionHolder()
        let reason = "unit test \(UUID().uuidString)"
        #expect(!holder.isHeld)

        holder.hold(reason: reason)
        defer { holder.release() }
        #expect(holder.isHeld)
        let whileHeld = try assertionsOutput()
        // One assertion each for idle sleep, system sleep and disk idle.
        #expect(whileHeld.components(separatedBy: reason).count - 1 == 3)

        holder.release()
        #expect(!holder.isHeld)
        #expect(!(try assertionsOutput()).contains(reason))
    }

    @Test func holdingTwiceDoesNotAddMoreAssertions() throws {
        let holder = PowerAssertionHolder()
        let reason = "unit test \(UUID().uuidString)"
        holder.hold(reason: reason)
        holder.hold(reason: reason)
        defer { holder.release() }
        #expect(try assertionsOutput().components(separatedBy: reason).count - 1 == 3)
    }

    @Test func releasingWhenNotHoldingIsHarmless() {
        let holder = PowerAssertionHolder()
        holder.release()
        #expect(!holder.isHeld)
    }
}
