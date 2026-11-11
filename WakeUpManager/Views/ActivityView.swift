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
    @Environment(MockStore.self) private var store

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
    @Environment(MockStore.self) private var store

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
    @Environment(MockStore.self) private var store

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
    @Environment(MockStore.self) private var store
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

struct WakeLogTab: View {
    @Environment(MockStore.self) private var store
    @State private var showAppleAndNetwork = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show Apple and network wakes", isOn: $showAppleAndNetwork)
                Card(title: nil) {
                    VStack(spacing: 0) {
                        ForEach(showAppleAndNetwork ? store.wakeLog : store.importantWakeLog) { entry in
                            WakeLogRow(entry: entry)
                                .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

struct WakeLogRow: View {
    let entry: WakeLogEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.time, format: .dateTime.weekday(.abbreviated).hour().minute())
                .monospacedDigit()
                .frame(width: 110, alignment: .leading)
            Pill(text: LocalizedStringKey(entry.kind), color: entry.kind == "Wake" ? .blue : .secondary)
            Text(entry.reason).foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ActivityView()
        .environment(MockStore())
        .frame(width: 900, height: 600)
}

#Preview("Blocked wakes") {
    BlockedWakesTab()
        .environment(MockStore())
        .frame(width: 900, height: 400)
}

#Preview("Wake log") {
    WakeLogTab()
        .environment(MockStore())
        .frame(width: 900, height: 400)
}
