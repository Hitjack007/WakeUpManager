//
//  SchedulerLink.swift
//  WakeUpManager
//
//  The app's connection to the scheduler agent: it asks for the status every couple of seconds, fills the
//  screens from the answer, and sends the user's decisions (approve, extend, stop, ...) back.
//

import Foundation
import SwiftUI
import WakeUpCore
import WakeUpSystem

/// Talks to the agent over its Unix socket. The socket calls block, so they run off the main actor.
struct SchedulerLink: Sendable {
    var client = SocketClient(timeout: 5)

    func send(_ message: ClientMessage) async throws -> ServerMessage {
        let client = client
        return try await Task.detached { try client.send(message) }.value
    }
}

extension SchedulerStore {
    /// Sends a control message to the agent and refreshes the screens. Returns `false` (and does nothing)
    /// while the screens show dummy data, so the caller can fall back to changing the dummy data.
    @discardableResult
    func send(_ message: ClientMessage) -> Bool {
        guard let link else { return false }
        Task {
            do {
                let reply = try await link.send(message)
                lastActionError = reply.ok ? nil : reply.error
            } catch {
                lastActionError = "Couldn't reach the scheduler: \(error.localizedDescription)"
            }
            await refresh()
        }
        return true
    }

    /// Asks the agent for its status and applies it.
    func refresh() async {
        guard let link else { return }
        do {
            let reply = try await link.send(.status())
            if let report = reply.status {
                apply(report)
                agentReachable = true
                await restartAgentIfOutOfDate(report)
            }
        } catch {
            agentReachable = false
            health = [HealthItem(
                id: "agent", title: "Scheduler agent",
                detail: "Not running. Switch it on in Settings > Permissions.", status: .problem)]
        }
    }

    /// The agent keeps running the program it started with, so after the app is updated or replaced it can be an
    /// older build than the one now inside the app (it then wouldn't understand newer messages). When the two
    /// differ, ask launchd to restart the agent, which starts the new one. Never while a job is running, because
    /// that would stop the job; it tries again on the next refresh instead.
    func restartAgentIfOutOfDate(_ report: StatusReport) async {
        guard !agentRestartAttempted else { return }
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Helpers/wakeup-agent")
        guard let expected = BuildFingerprint.ofFile(at: bundled), report.agentBuild != expected else { return }
        guard !report.executions.contains(where: { $0.state.isActive }) else { return }

        agentRestartAttempted = true
        let failure: String? = await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/launchctl")
            process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.wakeupmanager.agent"]
            let errors = Pipe()
            process.standardError = errors
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return error.localizedDescription
            }
            guard process.terminationStatus != 0 else { return nil }
            return String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        if let failure {
            lastActionError = "The scheduler is an older version and couldn't be restarted (\(failure)). Switch it off and on in System Settings > Login Items."
        }
    }

    /// Keeps the screens current for as long as the app is open. `onNewNotices` gets each notice the first
    /// time it appears, so the app can show it as a macOS notification.
    func runLive(onNewNotices: @escaping ([Notice]) -> Void) async {
        var seen: Set<UUID> = []
        var firstPass = true
        var pass = 0
        while !Task.isCancelled {
            await refresh()
            // Reading the wake history is slower than asking the agent, so do it about once a minute.
            if pass % 30 == 0 { await refreshWakeLog() }
            pass += 1
            if let link, let report = try? await link.send(.status()).status {
                let fresh = report.openNotices.filter { !seen.contains($0.id) }
                seen.formUnion(fresh.map(\.id))
                // Notices that were already open when the app started aren't news.
                if !firstPass { onNewNotices(fresh) }
                firstPass = false
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Reads the Mac's wake history (`pmset -g log`) for the Activity screen.
    func refreshWakeLog() async {
        let booked = knownWakeTimes
        let events = await Task.detached { (try? PmsetLogReader().recentWakes(scheduledWakes: booked)) ?? [] }.value
        wakeLog = events.map { event in
            WakeLogEntry(
                id: "\(event.time.timeIntervalSince1970)-\(event.kind)", time: event.time, kind: event.kind,
                reason: event.reason,
                source: Self.wakeSource(event.source))
        }
    }

    private static func wakeSource(_ source: WakeLogEvent.Source) -> WakeLogEntry.Source {
        switch source {
        case .scheduler: .scheduler
        case .apple: .apple
        case .network: .network
        case .user: .user
        }
    }

    // MARK: Turning a report into what the screens show

    func apply(_ report: StatusReport) {
        applyingReport = true
        defer { applyingReport = false }
        let saved = report.userSettings
        if batteryFloor != saved.batteryFloorPercent { batteryFloor = saved.batteryFloorPercent }
        if mediumAbove != saved.mediumAbovePercent { mediumAbove = saved.mediumAbovePercent }
        if highAbove != saved.highAbovePercent { highAbove = saved.highAbovePercent }
        if defaultLeadMinutes != saved.leadMinutes { defaultLeadMinutes = saved.leadMinutes }
        if missedGraceMinutes != saved.missedGraceMinutes { missedGraceMinutes = saved.missedGraceMinutes }

        let clientNames = Dictionary(uniqueKeysWithValues: report.clients.map { ($0.path, $0.displayName) })
        let jobCounts = Dictionary(grouping: report.jobs, by: \.clientPath).mapValues(\.count)

        clients = report.clients.map { record in
            MockClient(
                id: record.path, displayName: record.displayName,
                kind: record.path.hasSuffix(".app") ? .app : .project,
                status: Self.clientStatus(record.status),
                jobCount: jobCounts[record.path] ?? 0, lastRequest: record.lastRequest)
        }

        let clientStatus = Dictionary(uniqueKeysWithValues: report.clients.map { ($0.path, $0.status) })
        let latestFinished = Dictionary(
            report.recentHistory.map { ($0.jobKey, $0) }, uniquingKeysWith: { first, _ in first })
        jobs = report.jobs.map { entry in
            let key = entry.key
            let mine = report.executions.filter { $0.jobKey == key }
            let active = mine.first { $0.state.isActive }
            let next = mine.filter { $0.state == .scheduled }.min { $0.plannedStart < $1.plannedStart }
            return MockJob(
                id: key, name: entry.request.name,
                clientName: clientNames[entry.clientPath] ?? entry.request.client.displayName,
                repeatText: Self.repeatText(entry.request.schedule),
                nextRun: next?.plannedStart, plannedWake: next?.wakeAt,
                estimatedMinutes: entry.request.estimatedDurationMinutes,
                expectedCpu: entry.request.expectedCpuPercent, expectedGpu: entry.request.expectedGpuPercent,
                state: Self.jobState(
                    active: active, next: next, last: latestFinished[key],
                    clientStatus: clientStatus[entry.clientPath], awaitingConflict: entry.awaitingConflictDecision),
                method: { if case .app = entry.request.launch { "app" } else { "exec" } }(),
                command: Self.commandText(entry.request.launch),
                workingDirectory: { if case .exec(let exec) = entry.request.launch { exec.workingDirectory } else { nil } }(),
                minimumBattery: entry.settings.minimumBatteryPercent ?? batteryFloor,
                allowHighOnBattery: entry.settings.allowHighOnBattery,
                startedAt: active?.startedAt)
        }

        let expected = Dictionary(uniqueKeysWithValues: report.jobs.map { ($0.key, $0.request) })
        runs = report.recentHistory.map { execution in
            let request = expected[execution.jobKey]
            let start = execution.startedAt ?? execution.plannedStart
            let minutes = execution.endedAt.map { max(0, Int($0.timeIntervalSince(start) / 60)) } ?? 0
            return MockRun(
                id: execution.id.uuidString, jobName: execution.jobName, start: start, durationMinutes: minutes,
                outcome: Self.runOutcome(execution.state),
                // Actual CPU and GPU use isn't measured yet, so these stay at zero.
                avgCpu: 0, peakCpu: 0, avgGpu: 0, peakGpu: 0,
                expectedCpu: request?.expectedCpuPercent ?? 0, expectedGpu: request?.expectedGpuPercent ?? 0,
                note: execution.message)
        }

        mergeAlerts(report.openNotices)

        allowedWakeOwners = Set(report.allowedWakeOwners)
        blockedWakes = report.blockedWakes.map { wake in
            BlockedWake(
                id: wake.id.uuidString, owner: wake.owner, wakeAt: wake.wakeAt, cancelledAt: wake.handledAt,
                status: report.allowedWakeOwners.contains(wake.owner) ? .allowed : .blocked)
        }

        knownWakeTimes = (report.executions + report.recentHistory).map(\.wakeAt)
        holdingAwake = report.holdingAwake
        let power = BatteryPowerSensor().current()
        hasBattery = power.batteryPercent != nil
        switch (power.source, power.batteryPercent) {
        case (.ac, nil): powerDescription = "Plugged in"; powerDetail = "No battery"
        case (.ac, let percent?): powerDescription = "Plugged in"; powerDetail = "Battery at \(percent)%"
        case (.battery, let percent): powerDescription = "On battery"; powerDetail = percent.map { "\($0)% left" } ?? ""
        }

        health = [HealthItem(
            id: "agent", title: "Scheduler agent",
            detail: report.holdingAwake ? "Running, and holding the Mac awake." : "Running.", status: .ok)]
    }

    /// Open notices become open alerts. One that has disappeared was resolved, so it moves to the resolved list.
    private func mergeAlerts(_ notices: [Notice]) {
        let open = Set(notices.map(\.id.uuidString))
        var merged = alerts.map { alert -> MockAlert in
            var alert = alert
            if !open.contains(alert.id) { alert.resolved = true }
            return alert
        }
        for notice in notices {
            let id = notice.id.uuidString
            alertExecutions[id] = notice.executionId
            alertJobKeys[id] = notice.jobKey
            let alert = MockAlert(
                id: id, kind: Self.alertKind(notice.kind), title: notice.title, detail: notice.detail,
                date: notice.date, resolved: false)
            if let index = merged.firstIndex(where: { $0.id == id }) {
                merged[index] = alert
            } else {
                merged.insert(alert, at: 0)
            }
        }
        alerts = Array(merged.prefix(200))
    }

    // MARK: Small conversions

    private static func clientStatus(_ status: ClientRecord.Status) -> MockClient.Status {
        switch status {
        case .approved: .approved
        case .pending: .pending
        case .denied: .denied
        }
    }

    private static func runOutcome(_ state: Execution.State) -> MockRun.Outcome {
        switch state {
        case .completed: .success
        case .failed, .didNotStart: .failure
        case .stopped: .stopped
        default: .skipped
        }
    }

    private static func alertKind(_ kind: Notice.Kind) -> MockAlert.Kind {
        switch kind {
        case .overrun: .overrun
        case .blockedWake: .blockedWake
        case .approvalNeeded: .approval
        case .conflict: .overlap
        case .missed, .didNotStart, .failed, .batteryStopped, .wakeBookingFailed: .missed
        }
    }

    private static func jobState(
        active: Execution?, next: Execution?, last: Execution?,
        clientStatus: ClientRecord.Status?, awaitingConflict: Bool
    ) -> JobState {
        if let active { return active.state == .overrun ? .overrunning : .running }
        if awaitingConflict || clientStatus == .pending { return .awaitingApproval }
        if next != nil { return .scheduled }
        switch last?.state {
        case .completed: return .completed
        case .failed, .didNotStart, .stopped: return .failed
        case .missed, .cancelled: return .skipped
        default: return .scheduled
        }
    }

    private static func repeatText(_ schedule: Schedule) -> String {
        let time = schedule.start.split(separator: "T").last.map { String($0.prefix(5)) } ?? ""
        guard let rule = schedule.recurrence else { return "Once" }
        let every = rule.interval > 1
        switch rule.frequency {
        case .daily:
            return every ? "Every \(rule.interval) days \(time)" : "Daily \(time)"
        case .weekly:
            let days = (rule.daysOfWeek ?? []).map { String($0.rawValue.prefix(3)).capitalized }.joined(separator: ", ")
            let prefix = every ? "Every \(rule.interval) weeks" : "Weekly"
            return [prefix, days, time].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private static func commandText(_ launch: Launch) -> String {
        switch launch {
        case .exec(let exec): ([exec.executable] + exec.arguments).joined(separator: " ")
        case .app(let app): ([app.bundleId] + app.arguments).joined(separator: " ")
        }
    }
}
