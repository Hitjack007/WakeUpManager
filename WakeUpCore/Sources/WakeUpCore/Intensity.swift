import Foundation

/// How heavy a job is. Derived from the client's expected CPU and GPU use plus its estimated duration.
public enum IntensityLevel: String, Codable, Comparable, Equatable, Sendable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: IntensityLevel, rhs: IntensityLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// The limits that separate the levels (see "Resource intensity levels" in the design doc).
public struct IntensityThresholds: Equatable, Sendable {
    /// Low: at most this much CPU...
    public var lowMaxCpuPercent = 30
    /// ...at most this much GPU...
    public var lowMaxGpuPercent = 50
    /// ...and at most this long.
    public var lowMaxMinutes = 120
    /// High: strictly more than any one of these.
    public var highAboveCpuPercent = 80
    public var highAboveGpuPercent = 80
    public var highAboveMinutes = 180

    public init() {}
}

public extension IntensityLevel {
    /// High if any one limit is exceeded, low if all are within the low limits, otherwise medium.
    static func classify(
        expectedCpuPercent: Int,
        expectedGpuPercent: Int,
        estimatedDurationMinutes: Int,
        thresholds: IntensityThresholds = IntensityThresholds()
    ) -> IntensityLevel {
        if expectedCpuPercent > thresholds.highAboveCpuPercent
            || expectedGpuPercent > thresholds.highAboveGpuPercent
            || estimatedDurationMinutes > thresholds.highAboveMinutes {
            return .high
        }
        if expectedCpuPercent <= thresholds.lowMaxCpuPercent
            && expectedGpuPercent <= thresholds.lowMaxGpuPercent
            && estimatedDurationMinutes <= thresholds.lowMaxMinutes {
            return .low
        }
        return .medium
    }
}

public extension WakeRequest {
    /// The level the scheduler applies to this request.
    func intensityLevel(thresholds: IntensityThresholds = IntensityThresholds()) -> IntensityLevel {
        IntensityLevel.classify(
            expectedCpuPercent: expectedCpuPercent,
            expectedGpuPercent: expectedGpuPercent,
            estimatedDurationMinutes: estimatedDurationMinutes,
            thresholds: thresholds
        )
    }
}
