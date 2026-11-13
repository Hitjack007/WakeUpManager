//
//  OverviewView.swift
//  WakeUpManager
//

import SwiftUI

struct OverviewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                NextWakeCard()
                StatusRow()
                AttentionSection()
                UpcomingSection()
            }
            .padding(28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }
}

// MARK: - Next wake

/// The big card at the top: when the Mac wakes next, and for what.
struct NextWakeCard: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        Group {
            if let job = store.nextWakeJob, let wake = job.plannedWake, let start = job.nextRun {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Next wake", systemImage: "alarm.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(wake, format: .dateTime.weekday(.wide).hour().minute())
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("in \(Text(wake, style: .relative))")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(job.name).font(.title3.weight(.semibold)).lineLimit(2).multilineTextAlignment(.trailing)
                        Text("\(job.clientName), starts at \(Text(start, format: .dateTime.hour().minute()))")
                            .foregroundStyle(.white.opacity(0.85))
                        IntensityBadge(level: job.intensity)
                            .padding(2)
                            .background(.regularMaterial, in: Capsule())
                            .environment(\.colorScheme, .light)
                    }
                }
            } else {
                HStack(spacing: 16) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 34))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing is scheduled").font(.title2.weight(.semibold))
                        Text("Apps and scripts that book a wake will show up here.")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                }
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.dawn, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .brandIndigo.opacity(0.25), radius: 18, y: 8)
    }
}

// MARK: - Status tiles

struct StatusRow: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        // Tiles share the width and wrap onto a second row when the window is narrow, so nothing is cut off.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 16, alignment: .top)], spacing: 16) {
            if store.hasBattery {
                PowerTile()
            }
            HoldTile()
            BlockingTile()
        }
    }
}

struct StatusTile: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    let detail: String

    var body: some View {
        Card(title: nil) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(symbol: symbol, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(value).font(.title3.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

struct PowerTile: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        StatusTile(
            symbol: store.powerDescription == "On battery" ? "battery.50percent" : "powerplug.fill",
            tint: store.powerDescription == "On battery" ? .orange : .green,
            title: "Power",
            value: LocalizedStringKey(store.powerDescription), detail: store.powerDetail)
    }
}

struct HoldTile: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        if let job = store.runningJob {
            StatusTile(
                symbol: "bolt.fill", tint: .green, title: "Awake hold",
                value: "Holding the Mac awake", detail: job.name)
        } else {
            StatusTile(
                symbol: "moon.zzz", tint: .secondary, title: "Awake hold",
                value: "Not holding", detail: "The Mac may sleep when idle.")
        }
    }
}

struct BlockingTile: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        StatusTile(
            symbol: "hand.raised.fill", tint: .orange, title: "Wake blocking",
            value: "\(store.blockedThisWeek) blocked this week",
            detail: "Wakes from other apps are cancelled. Apple's are left alone.")
    }
}

// MARK: - Alerts needing attention

struct AttentionSection: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        if !store.openAlerts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Needs attention", count: store.openAlerts.count)
                ForEach(store.openAlerts) { alert in
                    AlertCard(alert: alert)
                }
            }
        }
    }
}

// MARK: - Upcoming

struct UpcomingSection: View {
    @Environment(SchedulerStore.self) private var store
    @State private var jobPendingCancel: MockJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Coming up", count: store.upcomingJobs.count)
            if store.upcomingJobs.isEmpty {
                Card(title: nil) {
                    Text("No jobs are waiting to run.").foregroundStyle(.secondary)
                }
            } else {
                Card(title: nil) {
                    VStack(spacing: 0) {
                        let shown = Array(store.upcomingJobs.prefix(6))
                        ForEach(shown) { job in
                            UpcomingRow(job: job, onCancel: { jobPendingCancel = job })
                            if job.id != shown.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .cancelJobConfirmation($jobPendingCancel)
    }
}

struct UpcomingRow: View {
    let job: MockJob
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: job.state.symbol, tint: job.state.color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).fontWeight(.medium).lineLimit(1)
                Text(job.clientName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if let start = job.nextRun {
                VStack(alignment: .trailing, spacing: 2) {
                    WhenText(date: start)
                    if let wake = job.plannedWake {
                        Text("wakes \(Text(wake, format: .dateTime.hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            IntensityBadge(level: job.intensity)
            StateBadge(state: job.state)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Cancel Job…", systemImage: "xmark.circle", role: .destructive, action: onCancel)
        }
    }
}

#Preview {
    OverviewView()
        .environment(SchedulerStore())
        .frame(width: 900, height: 760)
}
