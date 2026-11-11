//
//  ContentView.swift
//  WakeUpManager
//
//  Created by Mark Greene on 11/11/2026.
//

import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview, queue, clients, activity, alerts, settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .queue: "Queue"
        case .clients: "Clients"
        case .activity: "Activity"
        case .alerts: "Alerts"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "alarm"
        case .queue: "calendar.badge.clock"
        case .clients: "person.2"
        case .activity: "clock.arrow.circlepath"
        case .alerts: "bell"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(MockStore.self) private var store
    @State private var selection: SidebarSection? = .overview

    var body: some View {
        NavigationSplitView {
            SidebarList(
                selection: $selection,
                openAlerts: store.openAlertCount,
                pendingClients: store.pendingClients.count)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            DetailRouter(section: selection ?? .overview)
        }
        .frame(minWidth: 1020, minHeight: 640)
    }
}

struct SidebarList: View {
    @Binding var selection: SidebarSection?
    let openAlerts: Int
    let pendingClients: Int

    var body: some View {
        // The selection is a `SidebarSection`, not the row's id (a String), so each row needs an
        // explicit tag or clicking it selects nothing.
        List(selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .badge(badge(for: section))
                    .tag(section)
            }
        }
        .safeAreaInset(edge: .bottom) {
            AwakeFooter()
        }
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .alerts: openAlerts
        case .clients: pendingClients
        default: 0
        }
    }
}

/// A one-line status at the bottom of the sidebar: is the scheduler holding the Mac awake right now?
struct AwakeFooter: View {
    @Environment(MockStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.runningJob == nil ? Color.secondary : Color.green)
                .frame(width: 8, height: 8)
            if let job = store.runningJob {
                Text("Holding awake: \(job.name)")
            } else {
                Text("Not holding the Mac awake")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

struct DetailRouter: View {
    let section: SidebarSection

    var body: some View {
        switch section {
        case .overview: OverviewView()
        case .queue: QueueView()
        case .clients: ClientsView()
        case .activity: ActivityView()
        case .alerts: AlertsView()
        case .settings: SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(MockStore())
        .environment(PermissionsModel())
        .environment(ClaudeGuardModel())
}
