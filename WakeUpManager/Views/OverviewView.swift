//
//  OverviewView.swift
//  WakeUpManager
//

import SwiftUI

struct OverviewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NextWakeCard()
                StatusRow()
                AttentionSection()
                UpcomingSection()
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }
}

// MARK: - Next wake

struct NextWakeCard: View {
    @Environment(MockStore.self) private var store

    var body: some View {
        Card(title: "Next wake") {
            if let job = store.nextWakeJob, let wake = job.plannedWake, let start = job.nextRun {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(wake, format: .dateTime.weekday(.wide).hour().minute())
                            .font(.largeTitle.weight(.semibold))
                        Text("in \(Text(wake, style: .relative))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(job.name).font(.title3.weight(.medium))
                        Text("\(job.clientName), starts at \(Text(start, format: .dateTime.hour().minute()))")
                            .foregroundStyle(.secondary)
                        IntensityBadge(level: job.intensity)
                    }
                }
            } else {
                Text("Nothing is scheduled.").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Status tiles

struct StatusRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            PowerTile()
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
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

struct PowerTile: View {
    @Environment(MockStore.self) private var store

    var body: some View {
        StatusTile(
            symbol: "powerplug.fill", tint: .green, title: "Power",
            value: LocalizedStringKey(store.powerDescription), detail: store.powerDetail)
    }
}

struct HoldTile: View {
    @Environment(MockStore.self) private var store

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
    @Environment(MockStore.self) private var store

    var body: some View {
        StatusTile(
            symbol: "hand.raised.fill", tint: .orange, title: "Wake blocking",
            value: "\(store.blockedThisWeek) blocked this week",
            detail: "Wakes from other apps are cancelled. Apple's are left alone.")
    }
}

// MARK: - Alerts needing attention

struct AttentionSection: View {
    @Environment(MockStore.self) private var store

    var body: some View {
        if !store.openAlerts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Needs attention").font(.headline)
                ForEach(store.openAlerts) { alert in
                    AlertCard(alert: alert)
                }
            }
        }
    }
}

// MARK: - Upcoming

struct UpcomingSection: View {
    @Environment(MockStore.self) private var store

    var body: some View {
        Card(title: "Coming up") {
            VStack(spacing: 0) {
                ForEach(store.upcomingJobs.prefix(5)) { job in
                    UpcomingRow(job: job)
                    if job.id != store.upcomingJobs.prefix(5).last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

struct UpcomingRow: View {
    let job: MockJob

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).fontWeight(.medium)
                Text(job.clientName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
        .padding(.vertical, 8)
    }
}

#Preview {
    OverviewView()
        .environment(MockStore())
        .frame(width: 800, height: 700)
}
