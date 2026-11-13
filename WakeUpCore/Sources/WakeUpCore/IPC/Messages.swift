import Foundation

// The messages exchanged over the local socket. One JSON object per line: the client sends a
// `ClientMessage`, the scheduler answers with a `ServerMessage`, and the connection closes.

public struct ClientMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        // Anyone on this Mac may send these (the agent still checks who they say they are).
        case ping
        case submit
        case complete
        case cancelJob
        case status
        // Control messages. Only the WakeUp Manager app may send these.
        case approveClient
        case denyClient
        case revokeClient
        case extend
        case stop
        case resolveConflict
        case resolveNotice
        case setJobSettings
        case allowWakeOwner
        case updateSettings
        /// Removes any job by its key. `cancelJob` only works for the client that owns the job; this is the app's way.
        case removeJob
    }

    public var kind: Kind
    public var request: WakeRequest?
    public var report: CompletionReport?
    /// The client's location, for `cancelJob` and the client control messages.
    public var clientPath: String?
    public var jobId: String?
    public var jobKey: String?
    public var executionId: UUID?
    public var noticeId: UUID?
    public var minutes: Int?
    public var allowBoth: Bool?
    public var jobSettings: JobPowerSettings?
    /// The owner tag, for `allowWakeOwner`.
    public var owner: String?
    /// The settings, for `updateSettings`.
    public var userSettings: SchedulerSettings?

    public init(
        kind: Kind,
        request: WakeRequest? = nil,
        report: CompletionReport? = nil,
        clientPath: String? = nil,
        jobId: String? = nil,
        jobKey: String? = nil,
        executionId: UUID? = nil,
        noticeId: UUID? = nil,
        minutes: Int? = nil,
        allowBoth: Bool? = nil,
        jobSettings: JobPowerSettings? = nil,
        owner: String? = nil,
        userSettings: SchedulerSettings? = nil
    ) {
        self.userSettings = userSettings
        self.kind = kind
        self.request = request
        self.report = report
        self.clientPath = clientPath
        self.jobId = jobId
        self.jobKey = jobKey
        self.executionId = executionId
        self.noticeId = noticeId
        self.minutes = minutes
        self.allowBoth = allowBoth
        self.jobSettings = jobSettings
        self.owner = owner
    }

    public var isControl: Bool {
        switch kind {
        case .ping, .submit, .complete, .cancelJob, .status: false
        case .approveClient, .denyClient, .revokeClient, .extend, .stop, .resolveConflict, .resolveNotice,
             .setJobSettings, .allowWakeOwner, .updateSettings, .removeJob: true
        }
    }

    // MARK: Builders

    public static func ping() -> ClientMessage { ClientMessage(kind: .ping) }
    public static func status() -> ClientMessage { ClientMessage(kind: .status) }
    public static func submit(_ request: WakeRequest) -> ClientMessage { ClientMessage(kind: .submit, request: request) }
    public static func complete(_ report: CompletionReport) -> ClientMessage { ClientMessage(kind: .complete, report: report) }

    public static func cancelJob(clientPath: String, jobId: String) -> ClientMessage {
        ClientMessage(kind: .cancelJob, clientPath: clientPath, jobId: jobId)
    }

    public static func approveClient(path: String) -> ClientMessage { ClientMessage(kind: .approveClient, clientPath: path) }
    public static func denyClient(path: String) -> ClientMessage { ClientMessage(kind: .denyClient, clientPath: path) }
    public static func revokeClient(path: String) -> ClientMessage { ClientMessage(kind: .revokeClient, clientPath: path) }

    public static func extend(executionId: UUID, minutes: Int) -> ClientMessage {
        ClientMessage(kind: .extend, executionId: executionId, minutes: minutes)
    }

    public static func stop(executionId: UUID) -> ClientMessage { ClientMessage(kind: .stop, executionId: executionId) }

    public static func resolveConflict(jobKey: String, allowBoth: Bool) -> ClientMessage {
        ClientMessage(kind: .resolveConflict, jobKey: jobKey, allowBoth: allowBoth)
    }

    public static func resolveNotice(id: UUID) -> ClientMessage { ClientMessage(kind: .resolveNotice, noticeId: id) }

    public static func setJobSettings(jobKey: String, settings: JobPowerSettings) -> ClientMessage {
        ClientMessage(kind: .setJobSettings, jobKey: jobKey, jobSettings: settings)
    }

    public static func allowWakeOwner(_ owner: String) -> ClientMessage {
        ClientMessage(kind: .allowWakeOwner, owner: owner)
    }

    public static func updateSettings(_ settings: SchedulerSettings) -> ClientMessage {
        ClientMessage(kind: .updateSettings, userSettings: settings)
    }

    public static func removeJob(jobKey: String) -> ClientMessage {
        ClientMessage(kind: .removeJob, jobKey: jobKey)
    }
}

/// A snapshot of the scheduler for the `status` message and the app's screens.
public struct StatusReport: Codable, Equatable, Sendable {
    public var holdingAwake: Bool
    public var clients: [ClientRecord]
    public var executions: [Execution]
    public var recentHistory: [Execution]
    public var openNotices: [Notice]
    public var blockedWakes: [BlockedWake]
    public var allowedWakeOwners: [String]
    /// Every job the scheduler knows, with its request and its power settings.
    public var jobs: [JobEntry]
    /// What the user has set in the app.
    public var userSettings: SchedulerSettings
    /// Which build of the agent answered (see `BuildFingerprint`). Agents from before this existed leave it empty.
    public var agentBuild: String?

    public init(
        holdingAwake: Bool, clients: [ClientRecord], executions: [Execution],
        recentHistory: [Execution], openNotices: [Notice],
        blockedWakes: [BlockedWake] = [], allowedWakeOwners: [String] = [], jobs: [JobEntry] = [],
        userSettings: SchedulerSettings = SchedulerSettings(), agentBuild: String? = nil
    ) {
        self.agentBuild = agentBuild
        self.jobs = jobs
        self.userSettings = userSettings
        self.holdingAwake = holdingAwake
        self.clients = clients
        self.executions = executions
        self.recentHistory = recentHistory
        self.openNotices = openNotices
        self.blockedWakes = blockedWakes
        self.allowedWakeOwners = allowedWakeOwners
    }
}

public struct ServerMessage: Codable, Equatable, Sendable {
    public var ok: Bool
    public var response: WakeResponse?
    public var status: StatusReport?
    public var error: String?

    public init(ok: Bool, response: WakeResponse? = nil, status: StatusReport? = nil, error: String? = nil) {
        self.ok = ok
        self.response = response
        self.status = status
        self.error = error
    }

    public static func accepted() -> ServerMessage { ServerMessage(ok: true) }
    public static func answer(_ response: WakeResponse) -> ServerMessage { ServerMessage(ok: true, response: response) }
    public static func report(_ status: StatusReport) -> ServerMessage { ServerMessage(ok: true, status: status) }
    public static func failure(_ error: String) -> ServerMessage { ServerMessage(ok: false, error: error) }
}
