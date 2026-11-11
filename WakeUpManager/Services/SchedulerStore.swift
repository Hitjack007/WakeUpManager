//
//  SchedulerStore.swift
//  WakeUpManager
//
//  What the screens show. In the running app it is filled from the scheduler agent (see SchedulerLink.swift)
//  and every decision the user makes is sent back to the agent. With `sampleData: true` (previews) it holds
//  dummy data and just enough behaviour to make the screens feel real.
//

import SwiftUI
import WakeUpCore

@Observable
final class SchedulerStore {
    // MARK: Data

    var clients: [MockClient] {
        didSet { refreshClientGroups() }
    }
    var jobs: [MockJob] {
        didSet { refreshJobGroups() }
    }
    var runs: [MockRun]
    var alerts: [MockAlert] {
        didSet { refreshAlertGroups() }
    }
    var blockedWakes: [BlockedWake]
    var wakeLog: [WakeLogEntry] {
        didSet { importantWakeLog = wakeLog.filter { $0.source == .scheduler || $0.source == .user } }
    }
    /// The wake log without Apple maintenance and network wakes, prepared once.
    private(set) var importantWakeLog: [WakeLogEntry] = []
    var trend: TrendSuggestion?
    var health: [HealthItem]

    // MARK: Live connection (nil while the screens show dummy data)

    /// The scheduler agent, when the app is showing the real thing.
    var link: SchedulerLink?
    /// Whether the last attempt to reach the agent worked.
    var agentReachable = false
    /// Why the agent refused or couldn't do the last thing the app asked, if it didn't work.
    var lastActionError: String?
    /// The execution behind each alert, so Extend and Stop know what they act on.
    var alertExecutions: [String: UUID] = [:]
    /// The job behind each alert, for overlap decisions.
    var alertJobKeys: [String: String] = [:]
    /// Owners the user has allowed to book their own wakes.
    var allowedWakeOwners: Set<String> = []
    /// When the scheduler has booked wakes, so the wake log can tell its wakes from other ones.
    var knownWakeTimes: [Date] = []
    var powerDescription = "Plugged in"
    var powerDetail = "No battery (iMac)"
    var holdingAwake = false

    // MARK: Cached groups (recomputed when their inputs change, not on every body evaluation)

    private(set) var pendingClients: [MockClient] = []
    private(set) var approvedClients: [MockClient] = []
    private(set) var deniedClients: [MockClient] = []
    private(set) var upcomingJobs: [MockJob] = []
    private(set) var runningJob: MockJob?
    private(set) var nextWakeJob: MockJob?
    private(set) var openAlerts: [MockAlert] = []
    private(set) var resolvedAlerts: [MockAlert] = []

    // MARK: Settings

    var batteryFloor = 30 { didSet { settingsChanged() } }
    var mediumAbove = 80 { didSet { settingsChanged() } }
    var highAbove = 60 { didSet { settingsChanged() } }
    var missedGraceMinutes = 5 { didSet { settingsChanged() } }
    var defaultLeadMinutes = 5 { didSet { settingsChanged() } }
    /// True while the settings are being filled in from the agent, so that doesn't send them straight back.
    var applyingReport = false

    /// The settings as one value, for the agent.
    var schedulerSettings: SchedulerSettings {
        SchedulerSettings(
            batteryFloorPercent: batteryFloor, mediumAbovePercent: mediumAbove, highAbovePercent: highAbove,
            leadMinutes: defaultLeadMinutes, missedGraceMinutes: missedGraceMinutes)
    }

    private func settingsChanged() {
        guard !applyingReport else { return }
        send(.updateSettings(schedulerSettings))
    }

    // MARK: Status

    var blockedThisWeek: Int { blockedWakes.count }

    /// - Parameter sampleData: `true` fills the screens with dummy data (previews). The running app passes
    ///   `false` and fills them from the scheduler agent instead.
    init(sampleData: Bool = true) {
        clients = sampleData ? SchedulerStore.sampleClients : []
        jobs = sampleData ? SchedulerStore.sampleJobs : []
        runs = sampleData ? SchedulerStore.sampleRuns : []
        alerts = sampleData ? SchedulerStore.sampleAlerts : []
        blockedWakes = sampleData ? SchedulerStore.sampleBlockedWakes : []
        let log = sampleData ? SchedulerStore.sampleWakeLog : []
        wakeLog = log
        importantWakeLog = log.filter { $0.source == .scheduler || $0.source == .user }
        health = sampleData ? SchedulerStore.sampleHealth : []
        trend = sampleData
            ? TrendSuggestion(jobID: "nhl-game-recording", jobName: "NHL game recording", runs: 3, observedCpu: 56, expectedCpu: 45)
            : nil
        refreshClientGroups()
        refreshJobGroups()
        refreshAlertGroups()
    }

    // MARK: Lookups

    func job(id: String?) -> MockJob? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    func latestRun(forJobNamed name: String) -> MockRun? {
        runs.first { $0.jobName == name }
    }

    var openAlertCount: Int { openAlerts.count }

    // MARK: Projections for bindings

    subscript(minimumBatteryFor id: String) -> Int {
        get { job(id: id)?.minimumBattery ?? batteryFloor }
        set {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].minimumBattery = newValue
            sendJobSettings(index: index)
        }
    }

    subscript(allowHighOnBatteryFor id: String) -> Bool {
        get { job(id: id)?.allowHighOnBattery ?? false }
        set {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            jobs[index].allowHighOnBattery = newValue
            sendJobSettings(index: index)
        }
    }

    /// Tells the agent a job's power settings changed. The job's id is its key in the scheduler.
    private func sendJobSettings(index: Int) {
        let job = jobs[index]
        send(.setJobSettings(
            jobKey: job.id,
            settings: JobPowerSettings(
                minimumBatteryPercent: job.minimumBattery == batteryFloor ? nil : job.minimumBattery,
                allowHighOnBattery: job.allowHighOnBattery)))
    }

    // MARK: Actions

    func approve(clientID: String) {
        if send(.approveClient(path: clientID)) { return }
        setStatus(.approved, forClient: clientID)
        for index in jobs.indices where jobs[index].state == .awaitingApproval && jobs[index].clientName == clientName(for: clientID) {
            jobs[index].state = .scheduled
        }
        resolveAlerts(ofKind: .approval)
    }

    func deny(clientID: String) {
        if send(.denyClient(path: clientID)) { return }
        setStatus(.denied, forClient: clientID)
        resolveAlerts(ofKind: .approval)
    }

    func revoke(clientID: String) {
        if send(.revokeClient(path: clientID)) { return }
        setStatus(.denied, forClient: clientID)
    }

    func extendOverrun(alertID: String, minutes: Int) {
        if let executionId = alertExecutions[alertID], send(.extend(executionId: executionId, minutes: minutes)) {
            resolve(alertID: alertID)
            return
        }
        resolve(alertID: alertID)
        guard let index = jobs.firstIndex(where: { $0.state == .overrunning }) else { return }
        jobs[index].estimatedMinutes += minutes
        jobs[index].state = .running
    }

    func stopOverrun(alertID: String) {
        if let executionId = alertExecutions[alertID], send(.stop(executionId: executionId)) {
            resolve(alertID: alertID)
            return
        }
        resolve(alertID: alertID)
        guard let index = jobs.firstIndex(where: { $0.state == .overrunning }) else { return }
        jobs[index].state = .completed
    }

    func resolve(alertID: String) {
        guard let index = alerts.firstIndex(where: { $0.id == alertID }) else { return }
        alerts[index].resolved = true
        if let id = UUID(uuidString: alertID) { send(.resolveNotice(id: id)) }
    }

    /// Answers an overlap: run both jobs at once, or drop the new one.
    func resolveOverlap(alertID: String, allowBoth: Bool) {
        guard let jobKey = alertJobKeys[alertID] else { return }
        send(.resolveConflict(jobKey: jobKey, allowBoth: allowBoth))
    }

    func allowBlockedWake(id: String) {
        guard let index = blockedWakes.firstIndex(where: { $0.id == id }) else { return }
        if send(.allowWakeOwner(blockedWakes[index].owner)) { return }
        blockedWakes[index].status = .allowed
        resolveAlerts(ofKind: .blockedWake)
    }

    func allowLatestBlockedWake() {
        guard let wake = blockedWakes.first(where: { $0.status == .blocked }) else { return }
        allowBlockedWake(id: wake.id)
    }

    func approveFirstPending() {
        guard let client = pendingClients.first else { return }
        approve(clientID: client.id)
    }

    func denyFirstPending() {
        guard let client = pendingClients.first else { return }
        deny(clientID: client.id)
    }

    func applyTrend() {
        guard let trend, let index = jobs.firstIndex(where: { $0.id == trend.jobID }) else { return }
        jobs[index].expectedCpu = trend.observedCpu
        self.trend = nil
    }

    func dismissTrend() {
        trend = nil
    }

    // MARK: Private helpers

    private func clientName(for id: String) -> String? {
        clients.first { $0.id == id }?.displayName
    }

    private func setStatus(_ status: MockClient.Status, forClient id: String) {
        guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[index].status = status
    }

    private func resolveAlerts(ofKind kind: MockAlert.Kind) {
        for index in alerts.indices where alerts[index].kind == kind { alerts[index].resolved = true }
    }

    private func refreshClientGroups() {
        pendingClients = clients.filter { $0.status == .pending }
        approvedClients = clients.filter { $0.status == .approved }
        deniedClients = clients.filter { $0.status == .denied }
    }

    private func refreshJobGroups() {
        let active: Set<JobState> = [.scheduled, .awaitingApproval]
        upcomingJobs = jobs
            .filter { active.contains($0.state) && $0.nextRun != nil }
            .sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
        runningJob = jobs.first { $0.state == .running || $0.state == .overrunning }
        nextWakeJob = upcomingJobs.first { $0.state == .scheduled && $0.plannedWake != nil }
    }

    private func refreshAlertGroups() {
        openAlerts = alerts.filter { !$0.resolved }
        resolvedAlerts = alerts.filter { $0.resolved }
    }
}

// MARK: - Dummy data

extension SchedulerStore {
    static let sampleClients: [MockClient] = [
        MockClient(
            id: "/Users/mark/nhl-games-on-server/nhl-recorder", displayName: "NHL Recorder",
            kind: .project, status: .approved, jobCount: 3, lastRequest: .mock(hour: 1)),
        MockClient(
            id: "/Users/mark/ClaudeWriter", displayName: "ClaudeWriter",
            kind: .project, status: .approved, jobCount: 1, lastRequest: .mock(day: -1, hour: 23, minute: 30)),
        MockClient(
            id: "/Applications/Mail Archiver.app", displayName: "Mail Archiver",
            kind: .app, status: .approved, jobCount: 1, lastRequest: .mock(day: -3, hour: 6)),
        MockClient(
            id: "/Users/mark/Projects/backup-sweeper", displayName: "Backup Sweeper",
            kind: .project, status: .pending, jobCount: 1, lastRequest: .now.addingTimeInterval(-40 * 60)),
        MockClient(
            id: "/Users/mark/Projects/site-builder", displayName: "Site Builder",
            kind: .project, status: .denied, jobCount: 0, lastRequest: .mock(day: -6, hour: 9)),
    ]

    static let sampleJobs: [MockJob] = [
        MockJob(
            id: "claudewriter-chunk", name: "Book chunk run", clientName: "ClaudeWriter",
            repeatText: "Once", nextRun: nil, plannedWake: nil, estimatedMinutes: 40,
            expectedCpu: 20, expectedGpu: 0, state: .overrunning, method: "exec",
            command: "/Users/mark/.local/bin/claude -p \"/book resume\"",
            workingDirectory: "/Users/mark/ClaudeWriter", minimumBattery: 30, allowHighOnBattery: false,
            startedAt: .now.addingTimeInterval(-54 * 60)),
        MockJob(
            id: "nhl-daily-planner", name: "NHL daily planner", clientName: "NHL Recorder",
            repeatText: "Daily 01:00", nextRun: .mock(day: 1, hour: 1), plannedWake: .mock(day: 1, hour: 0, minute: 55),
            estimatedMinutes: 5, expectedCpu: 10, expectedGpu: 0, state: .scheduled, method: "exec",
            command: "/Users/mark/nhl-games-on-server/nhl-recorder/nhlrec.sh plan",
            workingDirectory: "/Users/mark/nhl-games-on-server/nhl-recorder", minimumBattery: 30, allowHighOnBattery: false,
            startedAt: nil),
        MockJob(
            id: "nhl-game-recording", name: "NHL game recording", clientName: "NHL Recorder",
            repeatText: "Per game", nextRun: .mock(day: 1, hour: 11, minute: 45), plannedWake: .mock(day: 1, hour: 11, minute: 30),
            estimatedMinutes: 200, expectedCpu: 45, expectedGpu: 85, state: .scheduled, method: "exec",
            command: "/Users/mark/nhl-games-on-server/nhl-recorder/nhlrec.sh record",
            workingDirectory: "/Users/mark/nhl-games-on-server/nhl-recorder", minimumBattery: 30, allowHighOnBattery: true,
            startedAt: nil),
        MockJob(
            id: "backup-nightly", name: "Nightly backup", clientName: "Backup Sweeper",
            repeatText: "Daily 03:00", nextRun: .mock(day: 1, hour: 3), plannedWake: nil,
            estimatedMinutes: 45, expectedCpu: 35, expectedGpu: 0, state: .awaitingApproval, method: "exec",
            command: "/usr/local/bin/python3 /Users/mark/Projects/backup-sweeper/run.py",
            workingDirectory: "/Users/mark/Projects/backup-sweeper", minimumBattery: 50, allowHighOnBattery: false,
            startedAt: nil),
        MockJob(
            id: "mail-archive", name: "Weekly archive", clientName: "Mail Archiver",
            repeatText: "Weekly Sun 06:00", nextRun: .mock(day: 4, hour: 6), plannedWake: .mock(day: 4, hour: 5, minute: 55),
            estimatedMinutes: 20, expectedCpu: 15, expectedGpu: 0, state: .scheduled, method: "app",
            command: "com.example.MailArchiver --archive",
            workingDirectory: nil, minimumBattery: 30, allowHighOnBattery: false,
            startedAt: nil),
        MockJob(
            id: "nhl-game-recording-2", name: "NHL game recording", clientName: "NHL Recorder",
            repeatText: "Per game", nextRun: .mock(day: 2, hour: 11, minute: 45), plannedWake: .mock(day: 2, hour: 11, minute: 30),
            estimatedMinutes: 200, expectedCpu: 45, expectedGpu: 85, state: .scheduled, method: "exec",
            command: "/Users/mark/nhl-games-on-server/nhl-recorder/nhlrec.sh record",
            workingDirectory: "/Users/mark/nhl-games-on-server/nhl-recorder", minimumBattery: 30, allowHighOnBattery: true,
            startedAt: nil),
    ]

    static let sampleRuns: [MockRun] = [
        MockRun(
            id: "run-1", jobName: "NHL daily planner", start: .mock(hour: 1), durationMinutes: 4, outcome: .success,
            avgCpu: 8, peakCpu: 14, avgGpu: 0, peakGpu: 0, expectedCpu: 10, expectedGpu: 0, note: nil),
        MockRun(
            id: "run-2", jobName: "NHL game recording", start: .mock(day: -1, hour: 11, minute: 45), durationMinutes: 192,
            outcome: .success, avgCpu: 56, peakCpu: 88, avgGpu: 71, peakGpu: 96, expectedCpu: 45, expectedGpu: 85,
            note: "Whisper finished 6 min after the final whistle."),
        MockRun(
            id: "run-3", jobName: "Book chunk run", start: .mock(day: -1, hour: 23, minute: 30), durationMinutes: 62,
            outcome: .success, avgCpu: 18, peakCpu: 41, avgGpu: 0, peakGpu: 0, expectedCpu: 20, expectedGpu: 0,
            note: "Ran 22 min over its estimate."),
        MockRun(
            id: "run-4", jobName: "Weekly archive", start: .mock(day: -3, hour: 6), durationMinutes: 0, outcome: .skipped,
            avgCpu: 0, peakCpu: 0, avgGpu: 0, peakGpu: 0, expectedCpu: 15, expectedGpu: 0,
            note: "Missed by 3 hours: the Mac was off."),
        MockRun(
            id: "run-5", jobName: "NHL game recording", start: .mock(day: -2, hour: 11, minute: 45), durationMinutes: 188,
            outcome: .success, avgCpu: 55, peakCpu: 86, avgGpu: 68, peakGpu: 94, expectedCpu: 45, expectedGpu: 85, note: nil),
        MockRun(
            id: "run-6", jobName: "Weekly archive", start: .mock(day: -10, hour: 6), durationMinutes: 9, outcome: .failure,
            avgCpu: 12, peakCpu: 30, avgGpu: 0, peakGpu: 0, expectedCpu: 15, expectedGpu: 0, note: "Exited with status 1."),
    ]

    static let sampleAlerts: [MockAlert] = [
        MockAlert(
            id: "alert-overrun", kind: .overrun, title: "Book chunk run is still going",
            detail: "ClaudeWriter's job is 14 minutes past its 40 minute estimate. The Mac is still being held awake.",
            date: .now.addingTimeInterval(-2 * 60), resolved: false),
        MockAlert(
            id: "alert-blocked", kind: .blockedWake, title: "Blocked a wake booked by another app",
            detail: "An event owned by \"brew-autoupdate\" for tomorrow 03:00 was cancelled. It was not one of Apple's.",
            date: .now.addingTimeInterval(-8 * 60), resolved: false),
        MockAlert(
            id: "alert-approval", kind: .approval, title: "Backup Sweeper wants to schedule jobs",
            detail: "/Users/mark/Projects/backup-sweeper asked for a daily 03:00 wake. Nothing runs until you approve it.",
            date: .now.addingTimeInterval(-40 * 60), resolved: false),
        MockAlert(
            id: "alert-missed", kind: .missed, title: "Weekly archive was skipped",
            detail: "It was due Sunday 06:00 but the Mac was off. Missed by more than 5 minutes, so it was skipped.",
            date: .mock(day: -3, hour: 9), resolved: true),
    ]

    static let sampleBlockedWakes: [BlockedWake] = [
        BlockedWake(
            id: "blocked-1", owner: "brew-autoupdate", wakeAt: .mock(day: 1, hour: 3),
            cancelledAt: .now.addingTimeInterval(-8 * 60), status: .blocked),
        BlockedWake(
            id: "blocked-2", owner: "com.example.cleaner.timer", wakeAt: .mock(day: -2, hour: 4),
            cancelledAt: .mock(day: -3, hour: 22), status: .blocked),
    ]

    static let sampleWakeLog: [WakeLogEntry] = [
        WakeLogEntry(id: "log-1", time: .mock(hour: 13, minute: 52), kind: "Wake", reason: "Booked for the wake test", source: .scheduler),
        WakeLogEntry(id: "log-2", time: .mock(hour: 13, minute: 48), kind: "DarkWake", reason: "Network: Wi-Fi and Bluetooth traffic", source: .network),
        WakeLogEntry(id: "log-3", time: .mock(hour: 7, minute: 30), kind: "Wake", reason: "Keyboard or mouse", source: .user),
        WakeLogEntry(id: "log-4", time: .mock(hour: 7, minute: 18), kind: "DarkWake", reason: "Apple: maintenance (mDNSResponder)", source: .apple),
        WakeLogEntry(id: "log-5", time: .mock(hour: 1, minute: 0), kind: "Wake", reason: "Booked for the NHL daily planner", source: .scheduler),
        WakeLogEntry(id: "log-6", time: .mock(day: -1, hour: 22, minute: 44), kind: "DarkWake", reason: "Apple: calendar refresh (calaccessd)", source: .apple),
        WakeLogEntry(id: "log-7", time: .mock(day: -1, hour: 16, minute: 59), kind: "Wake", reason: "Booked for the ClaudeWriter book chunk run", source: .scheduler),
        WakeLogEntry(id: "log-8", time: .mock(day: -1, hour: 11, minute: 30), kind: "Wake", reason: "Booked for the NHL game recording", source: .scheduler),
        WakeLogEntry(id: "log-9", time: .mock(day: -1, hour: 11, minute: 12), kind: "DarkWake", reason: "Network: Wi-Fi and Bluetooth traffic", source: .network),
        WakeLogEntry(id: "log-10", time: .mock(day: -1, hour: 8, minute: 2), kind: "Wake", reason: "Keyboard or mouse", source: .user),
        WakeLogEntry(id: "log-11", time: .mock(day: -1, hour: 1, minute: 0), kind: "Wake", reason: "Booked for the NHL daily planner", source: .scheduler),
    ]

    static let sampleHealth: [HealthItem] = [
        HealthItem(id: "helper", title: "Background helper", detail: "Approved in System Settings and responding.", status: .ok),
        HealthItem(id: "agent", title: "Scheduler agent", detail: "Running since 07:30.", status: .ok),
        HealthItem(id: "login-item", title: "Login item", detail: "Starts automatically when you log in.", status: .ok),
        HealthItem(
            id: "filevault", title: "FileVault is on",
            detail: "After a restart or power cut, nothing runs until someone unlocks this Mac.", status: .warning),
    ]
}
