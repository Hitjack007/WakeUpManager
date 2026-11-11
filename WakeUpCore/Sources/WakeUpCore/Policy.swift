import Foundation

// Power and timing rules from "Decisions made" in the design doc. Pure functions: no system access.

public struct PowerState: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case ac
        case battery
    }

    public var source: Source
    /// `nil` for a Mac with no battery.
    public var batteryPercent: Int?

    public init(source: Source, batteryPercent: Int? = nil) {
        self.source = source
        self.batteryPercent = batteryPercent
    }

    /// A desktop Mac, or a laptop on AC power.
    public static let plugged = PowerState(source: .ac)
}

public struct BatteryPolicy: Equatable, Sendable {
    /// No job runs below this (only while on battery).
    public var floorPercent = 30
    /// Medium jobs on battery need strictly more than this.
    public var mediumAbovePercent = 80
    /// High jobs on battery (if allowed for the job) need strictly more than this.
    public var highAbovePercent = 60

    public init() {}
}

/// Per-job settings made in the app UI.
public struct JobPowerSettings: Equatable, Sendable {
    /// An extra battery gate for this job.
    public var minimumBatteryPercent: Int?
    /// Whether a high-intensity job may run on battery at all.
    public var allowHighOnBattery: Bool

    public init(minimumBatteryPercent: Int? = nil, allowHighOnBattery: Bool = false) {
        self.minimumBatteryPercent = minimumBatteryPercent
        self.allowHighOnBattery = allowHighOnBattery
    }
}

public enum DenialReason: String, Equatable, Sendable {
    case batteryBelowFloor
    case batteryBelowJobMinimum
    case batteryTooLowForMedium
    case highNeedsACOrAllowedOnBattery
    case batteryTooLowForHigh
}

public enum PolicyDecision: Equatable, Sendable {
    case allow
    case deny(DenialReason)
}

public enum PowerPolicy {
    /// Whether a job of `level` may start now. On AC (or with no battery) everything is allowed.
    public static func evaluate(
        level: IntensityLevel,
        power: PowerState,
        policy: BatteryPolicy = BatteryPolicy(),
        job: JobPowerSettings = JobPowerSettings()
    ) -> PolicyDecision {
        guard power.source == .battery else { return .allow }
        // On battery with an unknown level: be cautious.
        let percent = power.batteryPercent ?? 0

        if percent < policy.floorPercent { return .deny(.batteryBelowFloor) }
        if let minimum = job.minimumBatteryPercent, percent < minimum { return .deny(.batteryBelowJobMinimum) }

        switch level {
        case .low:
            return .allow
        case .medium:
            return percent > policy.mediumAbovePercent ? .allow : .deny(.batteryTooLowForMedium)
        case .high:
            guard job.allowHighOnBattery else { return .deny(.highNeedsACOrAllowedOnBattery) }
            return percent > policy.highAbovePercent ? .allow : .deny(.batteryTooLowForHigh)
        }
    }

    /// Whether a job that is already running must be terminated. The 30% floor (and a job's own minimum)
    /// applies while running too.
    public static func shouldTerminateRunningJob(
        power: PowerState,
        policy: BatteryPolicy = BatteryPolicy(),
        job: JobPowerSettings = JobPowerSettings()
    ) -> Bool {
        guard power.source == .battery else { return false }
        let percent = power.batteryPercent ?? 0
        if percent < policy.floorPercent { return true }
        if let minimum = job.minimumBatteryPercent, percent < minimum { return true }
        return false
    }
}

public enum MissedAction: Equatable, Sendable {
    /// Start it as soon as possible.
    case runNow
    /// Don't start it; alert the user and wait for the next occurrence.
    case skipAndAlert
}

public struct MissedJobPolicy: Equatable, Sendable {
    /// Late by less than this: run. Late by this or more: skip and alert.
    public var graceSeconds: TimeInterval = 5 * 60

    public init() {}

    public func action(planned: Date, now: Date) -> MissedAction {
        now.timeIntervalSince(planned) < graceSeconds ? .runNow : .skipAndAlert
    }
}
