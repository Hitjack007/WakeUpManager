//
//  ActivityView.swift
//  WakeUpManager
//

import SwiftUI

enum ActivityTab: String, CaseIterable, Identifiable {
    case runs, blocked, wakeLog

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .runs: "Runs"
        case .blocked: "Blocked wakes"
        case .wakeLog: "Wake log"
        }
    }
}

struct ActivityView: View {
    @State private var tab: ActivityTab = .runs

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(ActivityTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(16)

            switch tab {
            case .runs: RunsTab()
            case .blocked: BlockedWakesTab()
            case .wakeLog: WakeLogTab()
            }
        }
        .navigationTitle("Activity")
    }
}

// MARK: - Runs

struct RunsTab: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            TrendBanner()
            Table(store.runs) {
                TableColumn("Job") { run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.jobName).fontWeight(.medium)
                        if let note = run.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 180, ideal: 240)
                TableColumn("Started") { run in
                    WhenText(date: run.start)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Took") { run in
                    Text(run.durationMinutes == 0 ? "-" : "\(run.durationMinutes) min")
                }
                .width(min: 60, ideal: 80)
                TableColumn("Outcome") { run in
                    OutcomeBadge(outcome: run.outcome)
                }
                .width(min: 90, ideal: 110)
                TableColumn("CPU (avg / peak)") { run in
                    UsageText(average: run.avgCpu, peak: run.peakCpu, expected: run.expectedCpu, skipped: run.outcome == .skipped)
                }
                .width(min: 120, ideal: 150)
                TableColumn("GPU (avg / peak)") { run in
                    UsageText(average: run.avgGpu, peak: run.peakGpu, expected: run.expectedGpu, skipped: run.outcome == .skipped)
                }
                .width(min: 120, ideal: 150)
            }
        }
    }
}

struct OutcomeBadge: View {
    let outcome: MockRun.Outcome

    var body: some View {
        switch outcome {
        case .success: Pill(text: "Success", color: .green, symbol: "checkmark")
        case .failure: Pill(text: "Failed", color: .red, symbol: "xmark")
        case .skipped: Pill(text: "Skipped", color: .secondary, symbol: "forward.end.fill")
        case .stopped: Pill(text: "Stopped", color: .orange, symbol: "stop.fill")
        }
    }
}

/// "56% / 88%" with a note when the average ran above what the client expected.
struct UsageText: View {
    let average: Int
    let peak: Int
    let expected: Int
    let skipped: Bool

    var body: some View {
        if skipped {
            Text("-").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                Text("\(average)% / \(peak)%")
                if average > expected + 5 {
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                        .help("Above the expected \(expected)%")
                }
            }
        }
    }
}

/// Shown when measured use has been above the expected figure for several runs in a row. The scheduler
/// only suggests a change; it never changes a job's numbers on its own.
struct TrendBanner: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        if let trend = store.trend {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(trend.jobName) is using more CPU than expected")
                        .fontWeight(.medium)
                    Text("Average \(trend.observedCpu)% over the last \(trend.runs) runs, against the \(trend.expectedCpu)% it asked for.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Not now") { store.dismissTrend() }
                Button("Update expected to \(trend.observedCpu)%") { store.applyTrend() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Blocked wakes

struct BlockedWakesTab: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Wakes booked by other apps are cancelled. Apple's own wakes are never touched.")
                    .foregroundStyle(.secondary)
                Card(title: nil) {
                    VStack(spacing: 0) {
                        ForEach(store.blockedWakes) { wake in
                            BlockedWakeRow(wake: wake)
                            if wake.id != store.blockedWakes.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

struct BlockedWakeRow: View {
    @Environment(SchedulerStore.self) private var store
    let wake: BlockedWake

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: wake.status == .blocked ? "hand.raised.fill" : "checkmark.shield")
                .foregroundStyle(wake.status == .blocked ? Color.orange : Color.green)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(wake.owner).font(.system(.body, design: .monospaced))
                Text("Wake for \(Text(wake.wakeAt, format: .dateTime.weekday(.abbreviated).hour().minute())), cancelled \(Text(wake.cancelledAt, format: .dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if wake.status == .blocked {
                Button("Allow this app") { store.allowBlockedWake(id: wake.id) }
            } else {
                Text("Allowed").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Wake log

enum WakeLogFilter: String, CaseIterable, Identifiable {
    case important, all

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .important: "Scheduler and you"
        case .all: "Everything"
        }
    }
}

struct WakeLogTab: View {
    @Environment(SchedulerStore.self) private var store
    @State private var filter: WakeLogFilter = .important

    var body: some View {
        VStack(spacing: 0) {
            WakeLogToolbar(
                filter: $filter,
                total: store.wakeLog.count,
                hidden: store.wakeLog.count - store.importantWakeLog.count)
            Table(filter == .all ? store.wakeLog : store.importantWakeLog) {
                TableColumn("When") { entry in
                    WakeLogTime(time: entry.time)
                }
                .width(min: 130, ideal: 150)
                TableColumn("Type") { entry in
                    Pill(text: entry.isDarkWake ? "DarkWake" : "Wake", color: entry.isDarkWake ? .secondary : .blue)
                }
                .width(min: 80, ideal: 90)
                TableColumn("Caused by") { entry in
                    WakeSourceLabel(source: entry.source)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Details") { entry in
                    Text(entry.reason)
                }
            }
        }
    }
}

/// The filter and a summary line above the wake log.
struct WakeLogToolbar: View {
    @Binding var filter: WakeLogFilter
    let total: Int
    let hidden: Int

    var body: some View {
        HStack(spacing: 16) {
            Picker("Show", selection: $filter) {
                ForEach(WakeLogFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            Spacer()
            if filter == .important && hidden > 0 {
                Text("^[\(hidden) wake](inflect: true) from macOS and the network hidden")
                    .foregroundStyle(.secondary)
            } else {
                Text("^[\(total) wake](inflect: true) in the last 2 days")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

/// "Today 1:52 PM" or "Yesterday 10:44 PM", then the weekday for anything older.
struct WakeLogTime: View {
    let time: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(time, format: .dateTime.hour().minute())
                .monospacedDigit()
            Text(dayLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var dayLabel: LocalizedStringKey {
        let calendar = Calendar.current
        if calendar.isDateInToday(time) { return "Today" }
        if calendar.isDateInYesterday(time) { return "Yesterday" }
        return LocalizedStringKey(time.formatted(.dateTime.weekday(.wide)))
    }
}

struct WakeSourceLabel: View {
    let source: WakeLogEntry.Source

    var body: some View {
        Label {
            Text(source.title)
        } icon: {
            Image(systemName: source.symbol)
                .foregroundStyle(source.tint)
        }
    }
}

extension WakeLogEntry.Source {
    var title: LocalizedStringKey {
        switch self {
        case .scheduler: "WakeUp Manager"
        case .user: "You"
        case .apple: "macOS"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .scheduler: "alarm"
        case .user: "hand.tap"
        case .apple: "gearshape.2"
        case .network: "wifi"
        }
    }

    var tint: Color {
        switch self {
        case .scheduler: .blue
        case .user: .green
        case .apple: .secondary
        case .network: .secondary
        }
    }
}

extension WakeLogEntry {
    var isDarkWake: Bool { kind == "DarkWake" }
}

#Preview {
    ActivityView()
        .environment(SchedulerStore())
        .frame(width: 900, height: 600)
}

#Preview("Blocked wakes") {
    BlockedWakesTab()
        .environment(SchedulerStore())
        .frame(width: 900, height: 400)
}

#Preview("Wake log") {
    WakeLogTab()
        .environment(SchedulerStore())
        .frame(width: 900, height: 400)
}
