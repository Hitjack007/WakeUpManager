import Foundation
import Testing
@testable import WakeUpCore

@Suite("Intensity levels")
struct IntensityTests {
    struct Case: Sendable {
        var cpu: Int
        var gpu: Int
        var minutes: Int
        var expected: IntensityLevel
    }

    @Test(arguments: [
        // low: up to 30% CPU, up to 50% GPU, up to 2 hours (limits inclusive)
        Case(cpu: 0, gpu: 0, minutes: 1, expected: .low),
        Case(cpu: 30, gpu: 50, minutes: 120, expected: .low),
        // just over a low limit: medium
        Case(cpu: 31, gpu: 0, minutes: 10, expected: .medium),
        Case(cpu: 0, gpu: 51, minutes: 10, expected: .medium),
        Case(cpu: 0, gpu: 0, minutes: 121, expected: .medium),
        // high needs to be strictly above 80% CPU, 80% GPU, or 3 hours
        Case(cpu: 80, gpu: 80, minutes: 180, expected: .medium),
        Case(cpu: 81, gpu: 0, minutes: 10, expected: .high),
        Case(cpu: 0, gpu: 81, minutes: 10, expected: .high),
        Case(cpu: 0, gpu: 0, minutes: 181, expected: .high),
        // any one limit is enough
        Case(cpu: 10, gpu: 10, minutes: 500, expected: .high),
    ])
    func classification(_ c: Case) {
        let level = IntensityLevel.classify(
            expectedCpuPercent: c.cpu, expectedGpuPercent: c.gpu, estimatedDurationMinutes: c.minutes)
        #expect(level == c.expected)
    }

    @Test func levelsAreOrdered() {
        #expect(IntensityLevel.low < .medium)
        #expect(IntensityLevel.medium < .high)
    }
}

@Suite("Power policy")
struct PowerPolicyTests {
    private func battery(_ percent: Int) -> PowerState { PowerState(source: .battery, batteryPercent: percent) }

    @Test(arguments: [IntensityLevel.low, .medium, .high])
    func everythingRunsOnACAndOnMacsWithoutABattery(_ level: IntensityLevel) {
        #expect(PowerPolicy.evaluate(level: level, power: .plugged) == .allow)
        #expect(PowerPolicy.evaluate(level: level, power: PowerState(source: .ac, batteryPercent: 5)) == .allow)
    }

    @Test func nothingRunsBelowTheFloorOnBattery() {
        for level in [IntensityLevel.low, .medium, .high] {
            let decision = PowerPolicy.evaluate(
                level: level, power: battery(29), job: JobPowerSettings(allowHighOnBattery: true))
            #expect(decision == .deny(.batteryBelowFloor))
        }
    }

    @Test func theFloorItselfIsAllowedForLow() {
        #expect(PowerPolicy.evaluate(level: .low, power: battery(30)) == .allow)
    }

    @Test func mediumNeedsMoreThanEightyPercentOnBattery() {
        #expect(PowerPolicy.evaluate(level: .medium, power: battery(80)) == .deny(.batteryTooLowForMedium))
        #expect(PowerPolicy.evaluate(level: .medium, power: battery(81)) == .allow)
    }

    @Test func highOnBatteryNeedsPermissionAndMoreThanSixtyPercent() {
        let allowed = JobPowerSettings(allowHighOnBattery: true)
        #expect(PowerPolicy.evaluate(level: .high, power: battery(95)) == .deny(.highNeedsACOrAllowedOnBattery))
        #expect(PowerPolicy.evaluate(level: .high, power: battery(60), job: allowed) == .deny(.batteryTooLowForHigh))
        #expect(PowerPolicy.evaluate(level: .high, power: battery(61), job: allowed) == .allow)
    }

    @Test func aJobsOwnMinimumAppliesOnTop() {
        let job = JobPowerSettings(minimumBatteryPercent: 50)
        #expect(PowerPolicy.evaluate(level: .low, power: battery(49), job: job) == .deny(.batteryBelowJobMinimum))
        #expect(PowerPolicy.evaluate(level: .low, power: battery(50), job: job) == .allow)
    }

    @Test func unknownBatteryLevelOnBatteryIsTreatedCautiously() {
        let unknown = PowerState(source: .battery, batteryPercent: nil)
        #expect(PowerPolicy.evaluate(level: .low, power: unknown) == .deny(.batteryBelowFloor))
    }

    @Test func runningJobsAreTerminatedBelowTheFloorOrTheirOwnMinimum() {
        #expect(PowerPolicy.shouldTerminateRunningJob(power: battery(29)))
        #expect(!PowerPolicy.shouldTerminateRunningJob(power: battery(30)))
        #expect(!PowerPolicy.shouldTerminateRunningJob(power: .plugged))
        let job = JobPowerSettings(minimumBatteryPercent: 50)
        #expect(PowerPolicy.shouldTerminateRunningJob(power: battery(45), job: job))
    }
}

@Suite("Missed jobs")
struct MissedJobTests {
    private let planned = instant("2026-11-12T07:00:00+13:00")

    @Test func lessThanFiveMinutesLateRunsNow() {
        let now = planned.addingTimeInterval(299)
        #expect(MissedJobPolicy().action(planned: planned, now: now) == .runNow)
    }

    @Test func fiveMinutesOrMoreLateIsSkippedAndAlerted() {
        #expect(MissedJobPolicy().action(planned: planned, now: planned.addingTimeInterval(300)) == .skipAndAlert)
        #expect(MissedJobPolicy().action(planned: planned, now: planned.addingTimeInterval(3_600)) == .skipAndAlert)
    }

    @Test func notYetDueIsNotMissed() {
        #expect(MissedJobPolicy().action(planned: planned, now: planned.addingTimeInterval(-10)) == .runNow)
    }
}
