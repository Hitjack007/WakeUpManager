//
//  ClientsView.swift
//  WakeUpManager
//

import SwiftUI

struct ClientsView: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PendingClientsSection()
                ApprovedClientsSection()
                DeniedClientsSection()
            }
            .padding(24)
        }
        .navigationTitle("Clients")
    }
}

struct PendingClientsSection: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        if !store.pendingClients.isEmpty {
            Card(title: "Waiting for approval") {
                ForEach(store.pendingClients) { client in
                    PendingClientRow(client: client)
                }
            }
        }
    }
}

struct ApprovedClientsSection: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        Card(title: "Approved") {
            if store.approvedClients.isEmpty {
                Text("No app or project is approved yet. When one asks the scheduler for a wake, it will wait here for your approval.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.approvedClients) { client in
                        ApprovedClientRow(client: client)
                        if client.id != store.approvedClients.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct DeniedClientsSection: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        if !store.deniedClients.isEmpty {
            Card(title: "Denied") {
                ForEach(store.deniedClients) { client in
                    DeniedClientRow(client: client)
                }
            }
        }
    }
}

/// The icon, name and location shared by every client row.
struct ClientIdentity: View {
    let name: String
    let path: String
    let kind: MockClient.Kind

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(symbol: kind == .app ? "macwindow" : "folder.fill", tint: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct PendingClientRow: View {
    @Environment(SchedulerStore.self) private var store
    let client: MockClient

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ClientIdentity(name: client.displayName, path: client.path, kind: client.kind)
                Text("Asked \(client.lastRequest.formatted(.relative(presentation: .named))). Approving allows every job from this \(client.kind == .app ? "app" : "project").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deny", role: .destructive) { store.deny(clientID: client.id) }
            Button("Approve") { store.approve(clientID: client.id) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }
}

struct ApprovedClientRow: View {
    @Environment(SchedulerStore.self) private var store
    let client: MockClient

    var body: some View {
        HStack(spacing: 12) {
            ClientIdentity(name: client.displayName, path: client.path, kind: client.kind)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("^[\(client.jobCount) job](inflect: true)")
                Text("Last request \(Text(client.lastRequest, format: .dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                Button("Revoke approval", role: .destructive) { store.revoke(clientID: client.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }
}

struct DeniedClientRow: View {
    @Environment(SchedulerStore.self) private var store
    let client: MockClient

    var body: some View {
        HStack(spacing: 12) {
            ClientIdentity(name: client.displayName, path: client.path, kind: client.kind)
            Spacer()
            Button("Allow again") { store.approve(clientID: client.id) }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    ClientsView()
        .environment(SchedulerStore())
        .frame(width: 800, height: 600)
}
