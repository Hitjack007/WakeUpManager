//
//  MockModels.swift
//  WakeUpManager
//
//  UI mockup only. These types hold dummy data so the screens can be reviewed before the real
//  scheduler exists. They will be replaced by the WakeUpCore types and real services.
//

import SwiftUI
import WakeUpCore

// MARK: - Intensity and state

enum Intensity: String, Equatable {
    case low, medium, high

    var title: LocalizedStringKey {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var color: Color {
        switch self {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    /// Uses the real classification from WakeUpCore (low is up to 30% CPU, 50% GPU and 2 hours; high is
    /// above 80% CPU, 80% GPU or 3 hours; everything else is medium).
    static func classify(cpu: Int, gpu: Int, minutes: Int) -> Intensity {
        switch IntensityLevel.classify(expectedCpuPercent: cpu, expectedGpuPercent: gpu, estimatedDurationMinutes: minutes) {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}

enum JobState: String, Equatable {
    case scheduled, awaitingApproval, running, overrunning, completed, failed, skipped

    var title: LocalizedStringKey {
        switch self {
        case .scheduled: "Scheduled"
        case .awaitingApproval: "Awaiting approval"
        case .running: "Running"
        case .overrunning: "Overrunning"
        case .completed: "Completed"
        case .failed: "Failed"
        case .skipped: "Skipped"
        }
    }

    var color: Color {
        switch self {
        case .scheduled: .blue
        case .awaitingApproval: .orange
        case .running: .green
        case .overrunning: .red
        case .completed: .secondary
        case .failed: .red
        case .skipped: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .scheduled: "calendar"
        case .awaitingApproval: "hand.raised.fill"
        case .running: "play.fill"
        case .overrunning: "exclamationmark.triangle.fill"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .skipped: "forward.end.fill"
        }
    }
}

// MARK: - Clients and jobs

struct MockClient: Identifiable, Equatable {
    enum Kind: Equatable { case project, app }
    enum Status: Equatable { case approved, pending, denied }

    /// The client's location, which is also its identity.
    let id: String
    var displayName: String
    var kind: Kind
    var status: Status
    var jobCount: Int
    var lastRequest: Date

    var path: String { id }
}

struct MockJob: Identifiable, Equatable {
    let id: String
    var name: String
    var clientName: String
    var repeatText: String
    var nextRun: Date?
    var plannedWake: Date?
    var estimatedMinutes: Int
    var expectedCpu: Int
    var expectedGpu: Int
    var state: JobState
    var method: String
    var command: String
    var workingDirectory: String?
    var minimumBattery: Int
    var allowHighOnBattery: Bool
    var startedAt: Date?

    var intensity: Intensity {
        Intensity.classify(cpu: expectedCpu, gpu: expectedGpu, minutes: estimatedMinutes)
    }
}

// MARK: - History, alerts and logs

struct MockRun: Identifiable, Equatable {
    enum Outcome: Equatable { case success, failure, skipped, stopped }

    let id: String
    var jobName: String
    var start: Date
    var durationMinutes: Int
    var outcome: Outcome
    var avgCpu: Int
    var peakCpu: Int
    var avgGpu: Int
    var peakGpu: Int
    var expectedCpu: Int
    var expectedGpu: Int
    var note: String?
}

struct MockAlert: Identifiable, Equatable {
    enum Kind: Equatable { case overrun, blockedWake, missed, approval }

    let id: String
    var kind: Kind
    var title: String
    var detail: String
    var date: Date
    var resolved: Bool
}

struct BlockedWake: Identifiable, Equatable {
    enum Status: Equatable { case blocked, allowed }

    let id: String
    var owner: String
    var wakeAt: Date
    var cancelledAt: Date
    var status: Status
}

struct WakeLogEntry: Identifiable, Equatable {
    enum Source: Equatable { case scheduler, apple, network, user }

    let id: String
    var time: Date
    var kind: String
    var reason: String
    var source: Source
}

struct TrendSuggestion: Equatable {
    var jobID: String
    var jobName: String
    var runs: Int
    var observedCpu: Int
    var expectedCpu: Int
}

struct HealthItem: Identifiable, Equatable {
    enum Status: Equatable { case ok, warning, problem }

    let id: String
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var status: Status
}

// MARK: - Dates for dummy data

extension Date {
    /// Today at the given time, shifted by `day` days (negative for the past). Mock data only.
    static func mock(day: Int = 0, hour: Int, minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let shifted = calendar.date(byAdding: .day, value: day, to: start) ?? start
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: shifted) ?? shifted
    }
}
