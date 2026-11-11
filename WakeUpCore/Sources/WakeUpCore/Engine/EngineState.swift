import Foundation

// The scheduler's persistent state: clients, jobs, planned and finished executions, and notices.
// Everything here is Codable so the engine can survive a restart.

public struct ClientRecord: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case approved, pending, denied
    }

    /// The client's verified location, which is also its identity.
    public var path: String
    public var displayName: String
    public var status: Status
    public var firstSeen: Date
    public var lastRequest: Date

    public init(path: String, displayName: String, status: Status, firstSeen: Date, lastRequest: Date) {
        self.path = path
        self.displayName = displayName
        self.status = status
        self.firstSeen = firstSeen
        self.lastRequest = lastRequest
    }
}

public enum JobKey {
    /// Jobs are unique per client, so the key combines the client's location and the job's own id.
    public static func make(clientPath: String, jobId: String) -> String {
        "\(clientPath)#\(jobId)"
    }
}

public struct JobEntry: Codable, Equatable, Sendable {
    public var request: WakeRequest
    public var clientPath: String
    public var settings: JobPowerSettings
    /// An overlap with another job is waiting for the user's decision; nothing is planned until it is made.
    public var awaitingConflictDecision: Bool
    /// The latest occurrence that has been turned into an execution (or recorded as missed).
    public var lastPlannedStart: Date?

    public var key: String { JobKey.make(clientPath: clientPath, jobId: request.jobId) }

    public init(
        request: WakeRequest,
        clientPath: String,
        settings: JobPowerSettings = JobPowerSettings(),
        awaitingConflictDecision: Bool = false,
        lastPlannedStart: Date? = nil
    ) {
        self.request = request
        self.clientPath = clientPath
        self.settings = settings
        self.awaitingConflictDecision = awaitingConflictDecision
        self.lastPlannedStart = lastPlannedStart
    }
}

/// One planned or finished run of a job.
public struct Execution: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Equatable, Sendable {
        /// Planned; waiting for its time (and for the power rules to allow it).
        case scheduled
        /// Launched; checking that it really started.
        case starting
        case running
        /// Still running after its estimate. The user has been told; nothing is terminated.
        case overrun
        case completed
        case failed
        /// The launch never produced a running job.
        case didNotStart
        /// Its start time was missed by too much (the Mac was off, or the power rules blocked it).
        case missed
        /// Terminated by the user or by the battery floor.
        case stopped
        case cancelled

        public var isActive: Bool {
            self == .starting || self == .running || self == .overrun
        }

        public var isFinished: Bool {
            switch self {
            case .completed, .failed, .didNotStart, .missed, .stopped, .cancelled: true
            case .scheduled, .starting, .running, .overrun: false
            }
        }
    }

    public let id: UUID
    public var jobKey: String
    public var jobName: String
    public var clientName: String
    public var estimatedMinutes: Int
    public var plannedStart: Date
    public var wakeAt: Date
    public var state: State
    public var startedAt: Date?
    public var endedAt: Date?
    /// When the estimate runs out (start plus estimate, plus any extensions).
    public var estimateEnd: Date?
    public var overrunNotified: Bool
    /// The launcher's handle for the running process or app.
    public var handle: String?
    /// When the launched process was seen to have exited, while still waiting for a completion report.
    public var exitedAt: Date?
    public var message: String?
    /// Why the power rules are holding it back, if they are.
    public var blockedBy: String?

    public init(
        id: UUID = UUID(),
        jobKey: String,
        jobName: String,
        clientName: String,
        estimatedMinutes: Int,
        plannedStart: Date,
        wakeAt: Date,
        state: State = .scheduled
    ) {
        self.id = id
        self.jobKey = jobKey
        self.jobName = jobName
        self.clientName = clientName
        self.estimatedMinutes = estimatedMinutes
        self.plannedStart = plannedStart
        self.wakeAt = wakeAt
        self.state = state
        self.overrunNotified = false
    }
}

/// Something the user should hear about. The engine keeps them and hands each to the notifier once.
public struct Notice: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case approvalNeeded
        case conflict
        case overrun
        case missed
        case didNotStart
        case failed
        case batteryStopped
        case wakeBookingFailed
        case blockedWake
    }

    public let id: UUID
    public var kind: Kind
    public var title: String
    public var detail: String
    public var date: Date
    public var executionId: UUID?
    public var jobKey: String?
    public var resolved: Bool

    public init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        detail: String,
        date: Date,
        executionId: UUID? = nil,
        jobKey: String? = nil,
        resolved: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.date = date
        self.executionId = executionId
        self.jobKey = jobKey
        self.resolved = resolved
    }
}

/// A wake booked by something other than the scheduler that the audit noticed.
public struct BlockedWake: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        /// The event was cancelled.
        case cancelled
        /// The event was noticed but left in place (the audit is in report-only mode).
        case reported
        /// Cancelling it failed.
        case cancelFailed
    }

    public let id: UUID
    /// The owner tag on the event, which says who booked it.
    public var owner: String
    /// The kind of event: `wake`, `poweron`, `sleep`, ...
    public var kind: String
    public var wakeAt: Date
    public var handledAt: Date
    public var outcome: Outcome
    public var detail: String?

    public init(
        id: UUID = UUID(), owner: String, kind: String, wakeAt: Date, handledAt: Date,
        outcome: Outcome, detail: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.wakeAt = wakeAt
        self.handledAt = handledAt
        self.outcome = outcome
        self.detail = detail
    }
}

public struct EngineState: Codable, Equatable, Sendable {
    public var clients: [String: ClientRecord] = [:]
    public var jobs: [String: JobEntry] = [:]
    /// Scheduled and active executions.
    public var executions: [Execution] = []
    /// Finished executions, newest last.
    public var history: [Execution] = []
    public var notices: [Notice] = []
    /// Responses already given, keyed by request id, so a repeated request gets the same answer.
    public var responses: [String: WakeResponse] = [:]
    /// Wakes the engine has booked through the helper and not yet seen fire or cancelled.
    public var bookedWakes: Set<Date> = []
    /// Wakes booked by other software that the audit noticed, newest last.
    public var blockedWakes: [BlockedWake] = []
    /// Owner tags the user has said are allowed to book their own wakes.
    public var allowedWakeOwners: Set<String> = []
    /// The rolling safety wake booked while a job runs, if one is booked.
    public var safetyWake: Date?
    /// What the user has set in the app. `nil` until they change something.
    public var userSettings: SchedulerSettings?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case clients, jobs, executions, history, notices, responses, bookedWakes, blockedWakes, allowedWakeOwners, safetyWake, userSettings
    }

    /// Fields added after the first version are optional on disk, so older state files still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clients = try c.decodeIfPresent([String: ClientRecord].self, forKey: .clients) ?? [:]
        jobs = try c.decodeIfPresent([String: JobEntry].self, forKey: .jobs) ?? [:]
        executions = try c.decodeIfPresent([Execution].self, forKey: .executions) ?? []
        history = try c.decodeIfPresent([Execution].self, forKey: .history) ?? []
        notices = try c.decodeIfPresent([Notice].self, forKey: .notices) ?? []
        responses = try c.decodeIfPresent([String: WakeResponse].self, forKey: .responses) ?? [:]
        bookedWakes = try c.decodeIfPresent(Set<Date>.self, forKey: .bookedWakes) ?? []
        blockedWakes = try c.decodeIfPresent([BlockedWake].self, forKey: .blockedWakes) ?? []
        allowedWakeOwners = try c.decodeIfPresent(Set<String>.self, forKey: .allowedWakeOwners) ?? []
        safetyWake = try c.decodeIfPresent(Date.self, forKey: .safetyWake)
        userSettings = try c.decodeIfPresent(SchedulerSettings.self, forKey: .userSettings)
    }
}

/// The settings the user can change in the app. They are saved with the state, so they survive a restart.
public struct SchedulerSettings: Codable, Equatable, Sendable {
    public var batteryFloorPercent: Int
    public var mediumAbovePercent: Int
    public var highAbovePercent: Int
    public var leadMinutes: Int
    public var missedGraceMinutes: Int

    public init(
        batteryFloorPercent: Int, mediumAbovePercent: Int, highAbovePercent: Int,
        leadMinutes: Int, missedGraceMinutes: Int
    ) {
        self.batteryFloorPercent = batteryFloorPercent
        self.mediumAbovePercent = mediumAbovePercent
        self.highAbovePercent = highAbovePercent
        self.leadMinutes = leadMinutes
        self.missedGraceMinutes = missedGraceMinutes
    }

    public init(from settings: EngineSettings = EngineSettings()) {
        batteryFloorPercent = settings.battery.floorPercent
        mediumAbovePercent = settings.battery.mediumAbovePercent
        highAbovePercent = settings.battery.highAbovePercent
        leadMinutes = settings.leadMinutes
        missedGraceMinutes = Int(settings.missedGraceSeconds / 60)
    }

    /// Puts these values into `settings`, leaving everything else as it was. Out-of-range values are clamped.
    public func apply(to settings: inout EngineSettings) {
        settings.battery.floorPercent = min(max(batteryFloorPercent, 0), 100)
        settings.battery.mediumAbovePercent = min(max(mediumAbovePercent, 0), 100)
        settings.battery.highAbovePercent = min(max(highAbovePercent, 0), 100)
        settings.leadMinutes = min(max(leadMinutes, 0), 120)
        settings.missedGraceSeconds = TimeInterval(min(max(missedGraceMinutes, 0), 120) * 60)
    }
}

/// Tunable values. The defaults follow the design doc.
public struct EngineSettings: Equatable, Sendable {
    /// The owner tag on every wake the engine books, so only its own wakes are ever cancelled.
    public var wakeOwner = "com.wakeupmanager.scheduler"
    /// How long before a job's start the Mac is woken.
    public var leadMinutes = 5
    /// A job later than this is skipped (and the user alerted); earlier than this, it runs.
    public var missedGraceSeconds: TimeInterval = 5 * 60
    /// How long after launching to wait before concluding that a job never started.
    public var startupCheckSeconds: TimeInterval = 60
    /// After a launched process exits without reporting, how long to wait for a late completion report.
    public var reportGraceSeconds: TimeInterval = 10
    /// While holding the Mac awake, keep holding if the next job starts within this long.
    public var keepAwakeGapSeconds: TimeInterval = 10 * 60
    /// How many upcoming occurrences of each job are planned (and their wakes booked).
    public var planAhead = 2
    /// While a job runs, a wake is kept booked this far ahead, so a Mac put to sleep by hand wakes itself
    /// and carries on. The wake is moved forward every `safetyWakeRefreshSeconds`.
    public var safetyWakeAheadSeconds: TimeInterval = 5 * 60
    public var safetyWakeRefreshSeconds: TimeInterval = 2 * 60
    /// Don't book a separate wake for a job that starts while an earlier job is expected to be holding
    /// the Mac awake. If that earlier job ends early, the wake is booked then.
    public var mergeNearbyWakes = true
    /// How often to check the battery while a job is running or waiting on the power rules.
    public var batteryPollSeconds: TimeInterval = 30
    public var maxHistory = 500
    public var battery = BatteryPolicy()
    public var thresholds = IntensityThresholds()

    public init() {}
}
