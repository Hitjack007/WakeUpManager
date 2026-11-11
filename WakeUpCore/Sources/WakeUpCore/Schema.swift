import Foundation

// The request, response and completion messages from WakeUpScheduler-Design.md ("Request schema").
// Wire format is JSON with camelCase keys. Dates in responses are ISO 8601 instants.

// MARK: - Request

public struct WakeRequest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var requestId: UUID
    public var client: ClientInfo
    public var jobId: String
    public var name: String
    public var schedule: Schedule
    public var estimatedDurationMinutes: Int
    /// Expected CPU use, 0-100. The scheduler derives the intensity level from this, never the client.
    public var expectedCpuPercent: Int
    /// Expected GPU use, 0-100.
    public var expectedGpuPercent: Int
    public var requires: [Requirement]
    public var launch: Launch
    public var completion: CompletionSpec

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = WakeRequest.currentSchemaVersion,
        requestId: UUID = UUID(),
        client: ClientInfo,
        jobId: String,
        name: String,
        schedule: Schedule,
        estimatedDurationMinutes: Int,
        expectedCpuPercent: Int,
        expectedGpuPercent: Int,
        requires: [Requirement] = [],
        launch: Launch,
        completion: CompletionSpec
    ) {
        self.schemaVersion = schemaVersion
        self.requestId = requestId
        self.client = client
        self.jobId = jobId
        self.name = name
        self.schedule = schedule
        self.estimatedDurationMinutes = estimatedDurationMinutes
        self.expectedCpuPercent = expectedCpuPercent
        self.expectedGpuPercent = expectedGpuPercent
        self.requires = requires
        self.launch = launch
        self.completion = completion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, requestId, client, jobId, name, schedule, estimatedDurationMinutes
        case expectedCpuPercent, expectedGpuPercent, requires, launch, completion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        requestId = try c.decode(UUID.self, forKey: .requestId)
        client = try c.decode(ClientInfo.self, forKey: .client)
        jobId = try c.decode(String.self, forKey: .jobId)
        name = try c.decode(String.self, forKey: .name)
        schedule = try c.decode(Schedule.self, forKey: .schedule)
        estimatedDurationMinutes = try c.decode(Int.self, forKey: .estimatedDurationMinutes)
        expectedCpuPercent = try c.decode(Int.self, forKey: .expectedCpuPercent)
        expectedGpuPercent = try c.decode(Int.self, forKey: .expectedGpuPercent)
        requires = try c.decodeIfPresent([Requirement].self, forKey: .requires) ?? []
        launch = try c.decode(Launch.self, forKey: .launch)
        completion = try c.decode(CompletionSpec.self, forKey: .completion)
    }
}

/// An app or project, identified by its location. Approval is per client, not per job.
public struct ClientInfo: Codable, Equatable, Sendable {
    public var displayName: String
    public var path: String

    public init(displayName: String, path: String) {
        self.displayName = displayName
        self.path = path
    }
}

public enum Requirement: String, Codable, Equatable, Sendable {
    /// Wait for the network to be reachable before launching.
    case network
}

// MARK: - Schedule

/// Local wall-clock schedule. Times are never stored as fixed UTC instants, so a 07:00 job stays at
/// 07:00 across daylight-saving changes. See `ScheduleResolver`.
public struct Schedule: Codable, Equatable, Sendable {
    /// Local date and time of the first (or only) start, `yyyy-MM-dd'T'HH:mm[:ss]`.
    public var start: String
    /// `"system"` (the Mac's current zone) or an IANA identifier such as `Pacific/Auckland`.
    public var timeZone: String
    public var recurrence: Recurrence?

    public static let systemTimeZone = "system"

    public init(start: String, timeZone: String = Schedule.systemTimeZone, recurrence: Recurrence? = nil) {
        self.start = start
        self.timeZone = timeZone
        self.recurrence = recurrence
    }

    private enum CodingKeys: String, CodingKey {
        case start, timeZone
        case recurrence = "repeat"
    }
}

public struct Recurrence: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, Equatable, Sendable {
        case daily
        case weekly
    }

    public var frequency: Frequency
    public var interval: Int
    /// Weekly only. Defaults to the weekday of `Schedule.start`.
    public var daysOfWeek: [Weekday]?
    /// Local date and time after which no more occurrences are made (inclusive).
    public var until: String?

    public init(frequency: Frequency, interval: Int = 1, daysOfWeek: [Weekday]? = nil, until: String? = nil) {
        self.frequency = frequency
        self.interval = interval
        self.daysOfWeek = daysOfWeek
        self.until = until
    }

    private enum CodingKeys: String, CodingKey {
        case frequency, interval, daysOfWeek, until
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decode(Frequency.self, forKey: .frequency)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        daysOfWeek = try c.decodeIfPresent([Weekday].self, forKey: .daysOfWeek)
        until = try c.decodeIfPresent(String.self, forKey: .until)
    }
}

public enum Weekday: String, Codable, CaseIterable, Equatable, Sendable {
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    /// `Calendar` weekday numbering: Sunday is 1.
    public var calendarValue: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }

    public init?(calendarValue: Int) {
        guard let match = Weekday.allCases.first(where: { $0.calendarValue == calendarValue }) else { return nil }
        self = match
    }
}

// MARK: - Launch

/// How the scheduler starts the job. Encoded with a `method` discriminator: `exec` or `app`.
public enum Launch: Equatable, Sendable {
    case exec(ExecLaunch)
    case app(AppLaunch)
}

public struct ExecLaunch: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case executable, arguments, workingDirectory, environment
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }
}

public struct AppLaunch: Codable, Equatable, Sendable {
    public var bundleId: String
    public var arguments: [String]
    public var url: String?

    public init(bundleId: String, arguments: [String] = [], url: String? = nil) {
        self.bundleId = bundleId
        self.arguments = arguments
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case bundleId, arguments, url
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url)
    }
}

extension Launch: Codable {
    private enum MethodKey: String, CodingKey {
        case method
    }

    private enum Method: String, Codable {
        case exec
        case app
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: MethodKey.self)
        switch try c.decode(Method.self, forKey: .method) {
        case .exec: self = .exec(try ExecLaunch(from: decoder))
        case .app: self = .app(try AppLaunch(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: MethodKey.self)
        switch self {
        case .exec(let launch):
            try c.encode(Method.exec, forKey: .method)
            try launch.encode(to: encoder)
        case .app(let launch):
            try c.encode(Method.app, forKey: .method)
            try launch.encode(to: encoder)
        }
    }
}

public struct CompletionSpec: Codable, Equatable, Sendable {
    public enum Reporter: String, Codable, Equatable, Sendable {
        /// The launched process exiting means the job is done (`exec` only).
        case processExit
        /// The job calls the completion CLI as its final action.
        case client
        /// The launched app quitting means the job is done.
        case appQuit
    }

    public var reportedBy: Reporter

    public init(reportedBy: Reporter) {
        self.reportedBy = reportedBy
    }
}

// MARK: - Response

public struct WakeResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case authorised
        case rejected
        /// Waiting for the user to approve the client in the app UI.
        case pendingApproval
        /// An overlap waiting for the user's decision.
        case conflict
    }

    public var requestId: UUID
    public var status: Status
    public var reasonCode: ReasonCode
    public var message: String
    public var plannedWakeAt: Date?
    public var plannedStartAt: Date?
    public var conflicts: [ConflictInfo]

    public init(
        requestId: UUID,
        status: Status,
        reasonCode: ReasonCode,
        message: String,
        plannedWakeAt: Date? = nil,
        plannedStartAt: Date? = nil,
        conflicts: [ConflictInfo] = []
    ) {
        self.requestId = requestId
        self.status = status
        self.reasonCode = reasonCode
        self.message = message
        self.plannedWakeAt = plannedWakeAt
        self.plannedStartAt = plannedStartAt
        self.conflicts = conflicts
    }
}

public enum ReasonCode: String, Codable, Equatable, Sendable {
    case ok
    case clientNotApproved
    case clientLocationMismatch
    case invalidRequest
    case batteryPolicy
    case overlapsOtherJob
}

public struct ConflictInfo: Codable, Equatable, Sendable {
    public var jobId: String
    public var startAt: Date

    public init(jobId: String, startAt: Date) {
        self.jobId = jobId
        self.startAt = startAt
    }
}

// MARK: - Completion report

/// The client's final action. `reschedule` asks for a follow-up run at an absolute instant.
public struct CompletionReport: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case success
        case failure
        case partial
    }

    public struct Reschedule: Codable, Equatable, Sendable {
        public var startAt: Date
        public var estimatedDurationMinutes: Int

        public init(startAt: Date, estimatedDurationMinutes: Int) {
            self.startAt = startAt
            self.estimatedDurationMinutes = estimatedDurationMinutes
        }
    }

    public var executionId: UUID
    public var outcome: Outcome
    public var message: String?
    public var reschedule: Reschedule?

    public init(executionId: UUID, outcome: Outcome, message: String? = nil, reschedule: Reschedule? = nil) {
        self.executionId = executionId
        self.outcome = outcome
        self.message = message
        self.reschedule = reschedule
    }
}

// MARK: - JSON coding

/// Shared encoder and decoder settings, so every component reads and writes the same wire format.
public enum WakeUpJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    /// One line, no pretty printing: used on the wire, where a newline ends a message.
    public static func makeCompactEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
