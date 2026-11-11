//
//  PermissionsView.swift
//  WakeUpManager
//
//  The Permissions tab in Settings. Each permission is a card like DynamicNotch's permission requests:
//  an icon, what it is for, a privacy note, and Not Now / Allow Access. Allow Access brings up the
//  macOS prompt. "Go through them" walks the outstanding ones one at a time.
//

import SwiftUI

struct PermissionsView: View {
    @Environment(PermissionsModel.self) private var permissions
    @State private var showingWalkthrough = false

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Allowing one brings up the macOS prompt, or opens System Settings if macOS needs you to switch it on there.")
            }

            Section {
                Button("Go through them…") { showingWalkthrough = true }
                    .disabled(permissions.outstanding.isEmpty)
            } footer: {
                if permissions.allAllowed {
                    Text("Everything is allowed.")
                } else if permissions.outstanding.isEmpty {
                    Text("Nothing left to ask for here. Anything turned off has to be changed in System Settings.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await permissions.refresh()
            // Switching something on in System Settings doesn't tell us, so look again when the app returns.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await permissions.refresh()
            }
        }
        .sheet(isPresented: $showingWalkthrough) {
            PermissionWalkthrough(isPresented: $showingWalkthrough)
        }
    }
}

// MARK: - One permission in the list

struct PermissionRow: View {
    @Environment(PermissionsModel.self) private var permissions
    let kind: PermissionKind

    var body: some View {
        let status = permissions.status(of: kind)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(kind.title).font(.headline)
                    PermissionStatusPill(status: status)
                }
                Text(kind.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if case .unavailable(let reason) = status {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            PermissionAction(kind: kind, status: status)
        }
        .padding(.vertical, 4)
    }
}

struct PermissionStatusPill: View {
    let status: PermissionStatus

    var body: some View {
        switch status {
        case .allowed: Pill(text: "Allowed", color: .green, symbol: "checkmark")
        case .notAsked: Pill(text: "Not asked yet", color: .secondary)
        case .needsApproval: Pill(text: "Waiting for you in System Settings", color: .orange, symbol: "hourglass")
        case .denied: Pill(text: "Turned off", color: .red, symbol: "xmark")
        case .unavailable: Pill(text: "Not available", color: .secondary)
        }
    }
}

/// The button for a row: ask, open System Settings, or nothing if it's already allowed.
struct PermissionAction: View {
    @Environment(PermissionsModel.self) private var permissions
    let kind: PermissionKind
    let status: PermissionStatus

    var body: some View {
        switch status {
        case .allowed, .unavailable:
            EmptyView()
        case .notAsked:
            Button(kind.allowTitle) { Task { await permissions.request(kind) } }
                .buttonStyle(.borderedProminent)
                .disabled(permissions.asking != nil)
        case .needsApproval, .denied:
            Button("Open System Settings") { permissions.openSystemSettings(for: kind) }
                .buttonStyle(.bordered)
        }
    }
}

// MARK: - Walking through them

/// The same card DynamicNotch shows for each permission, one after another.
struct PermissionWalkthrough: View {
    @Environment(PermissionsModel.self) private var permissions
    @Binding var isPresented: Bool
    @State private var queue: [PermissionKind] = []
    @State private var started = false

    var body: some View {
        Group {
            if let kind = queue.first {
                PermissionRequestCard(
                    kind: kind,
                    onAllow: {
                        Task {
                            await permissions.request(kind)
                            advance()
                        }
                    },
                    onSkip: { advance() })
                    .id(kind)
            } else if started {
                ContentUnavailableView(
                    "That's everything", systemImage: "checkmark.circle",
                    description: Text("You can change any of these later in this tab or in System Settings."))
                    .overlay(alignment: .bottom) {
                        Button("Done") { isPresented = false }
                            .keyboardShortcut(.defaultAction)
                            .padding(.bottom, 24)
                    }
            }
        }
        .frame(width: 480, height: 420)
        .task {
            await permissions.refresh()
            queue = permissions.outstanding
            started = true
            if queue.isEmpty { isPresented = false }
        }
    }

    private func advance() {
        if !queue.isEmpty { queue.removeFirst() }
    }
}

struct PermissionRequestCard: View {
    let kind: PermissionKind
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: kind.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 56)
                .foregroundStyle(.tint)
                .padding(.top, 32)

            Text(kind.title)
                .font(.title)
                .fontWeight(.semibold)

            Text(kind.summary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text(kind.privacyNote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal)

            HStack {
                Button("Not Now", action: onSkip)
                    .buttonStyle(.bordered)
                Button(kind.allowTitle, action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#Preview {
    PermissionsView()
        .environment(PermissionsModel())
        .frame(width: 700, height: 500)
}
