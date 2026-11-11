//
//  AlertsView.swift
//  WakeUpManager
//

import SwiftUI

struct AlertsView: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        Group {
            if store.openAlerts.isEmpty && store.resolvedAlerts.isEmpty {
                ContentUnavailableView("No alerts", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        OpenAlertsSection()
                        ResolvedAlertsSection()
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Alerts")
    }
}

struct OpenAlertsSection: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        if store.openAlerts.isEmpty {
            Label("Nothing needs your attention.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.openAlerts) { alert in
                AlertCard(alert: alert)
            }
        }
    }
}

struct ResolvedAlertsSection: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        if !store.resolvedAlerts.isEmpty {
            Text("Resolved").font(.headline).padding(.top, 12)
            ForEach(store.resolvedAlerts) { alert in
                AlertCard(alert: alert)
            }
        }
    }
}

// MARK: - Alert card

extension MockAlert.Kind {
    var symbol: String {
        switch self {
        case .overrun: "exclamationmark.triangle.fill"
        case .blockedWake: "hand.raised.fill"
        case .missed: "forward.end.fill"
        case .approval: "person.badge.shield.checkmark"
        case .overlap: "calendar.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .overrun: .red
        case .blockedWake: .orange
        case .missed: .secondary
        case .approval: .blue
        case .overlap: .orange
        }
    }
}

struct AlertCard: View {
    @Environment(SchedulerStore.self) private var store
    let alert: MockAlert

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: alert.kind.symbol)
                .font(.title2)
                .foregroundStyle(alert.kind.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(alert.title).font(.headline)
                    Spacer()
                    Text(alert.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(alert.detail).foregroundStyle(.secondary)
                if !alert.resolved {
                    AlertActions(alertID: alert.id, kind: alert.kind)
                        .padding(.top, 6)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .opacity(alert.resolved ? 0.6 : 1)
    }
}

struct AlertActions: View {
    @Environment(SchedulerStore.self) private var store
    let alertID: String
    let kind: MockAlert.Kind

    var body: some View {
        HStack {
            switch kind {
            case .overrun:
                Button("Extend 30 min") { store.extendOverrun(alertID: alertID, minutes: 30) }
                    .buttonStyle(.borderedProminent)
                Button("Stop job", role: .destructive) { store.stopOverrun(alertID: alertID) }
            case .blockedWake:
                Button("Allow this app") { store.allowLatestBlockedWake() }
                Button("Keep blocked") { store.resolve(alertID: alertID) }
            case .approval:
                Button("Approve") { store.approveFirstPending() }
                    .buttonStyle(.borderedProminent)
                Button("Deny", role: .destructive) { store.denyFirstPending() }
            case .overlap:
                Button("Run both") { store.resolveOverlap(alertID: alertID, allowBoth: true) }
                    .buttonStyle(.borderedProminent)
                Button("Drop the new job", role: .destructive) { store.resolveOverlap(alertID: alertID, allowBoth: false) }
            case .missed:
                Button("Dismiss") { store.resolve(alertID: alertID) }
            }
        }
    }
}

#Preview {
    AlertsView()
        .environment(SchedulerStore())
        .frame(width: 800, height: 600)
}
