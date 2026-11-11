//
//  SettingsView.swift
//  WakeUpManager
//

import SwiftUI

struct SettingsView: View {
    @Environment(MockStore.self) private var store

    var body: some View {
        Form {
            BatterySection(store: store)
            IntensitySection()
            TimingSection(store: store)
            ClaudeGuardSection(store: store)
            HealthSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

// MARK: - Battery

struct BatterySection: View {
    @Bindable var store: MockStore

    var body: some View {
        Section {
            Stepper("No job runs below \(store.batteryFloor)%", value: $store.batteryFloor, in: 10...50, step: 5)
            Stepper("Medium jobs on battery need more than \(store.mediumAbove)%", value: $store.mediumAbove, in: 50...95, step: 5)
            Stepper("High jobs on battery need more than \(store.highAbove)%", value: $store.highAbove, in: 30...90, step: 5)
        } header: {
            Text("Battery")
        } footer: {
            Text("On AC power every job runs. High jobs also need to be allowed on battery, per job, in the queue.")
        }
    }
}

// MARK: - Intensity levels

struct IntensitySection: View {
    var body: some View {
        Section {
            LabeledContent("Low") { Text("up to 30% CPU, 50% GPU, 2 hours") }
            LabeledContent("Medium") { Text("everything in between") }
            LabeledContent("High") { Text("above 80% CPU, 80% GPU, or over 3 hours") }
        } header: {
            Text("Intensity levels")
        } footer: {
            Text("Apps only say how much CPU and GPU they expect to use. The level is worked out here.")
        }
    }
}

// MARK: - Timing

struct TimingSection: View {
    @Bindable var store: MockStore

    var body: some View {
        Section {
            Stepper("Wake the Mac \(store.defaultLeadMinutes) min before a job", value: $store.defaultLeadMinutes, in: 1...30)
            Stepper("Run a late job if it's under \(store.missedGraceMinutes) min late", value: $store.missedGraceMinutes, in: 1...30)
        } header: {
            Text("Timing")
        } footer: {
            Text("A job that is later than this is skipped and you are alerted.")
        }
    }
}

// MARK: - Claude Code guard

struct ClaudeGuardSection: View {
    @Bindable var store: MockStore

    var body: some View {
        Section {
            LabeledContent("Claude Code guard") {
                if store.claudeGuardInstalled {
                    Button("Remove") { store.claudeGuardInstalled = false }
                } else {
                    Button("Install...") { store.claudeGuardInstalled = true }
                }
            }
            Text(store.claudeGuardInstalled
                 ? "Installed in ~/.claude/settings.json. Claude Code is told to use the scheduler instead of booking wakes itself."
                 : "Not installed. Claude Code could book wakes or keep-awake jobs on its own.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("What will be added") {
                MonospacedLine(text: "hooks.PreToolUse: block pmset schedule / repeat, caffeinate and new launch agents, and point to the agent guide")
            }
            Toggle("Developer mode", isOn: $store.devModeEnabled)
            if store.devModeEnabled {
                Picker("Turns off after", selection: $store.devModeMinutes) {
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("4 hours").tag(240)
                }
                Text("While on, direct wake commands are allowed so tests can book real wakes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("Installing edits another tool's settings file. A backup is made first, and Remove only takes out what was added.")
        }
    }
}

// MARK: - Health

struct HealthSection: View {
    @Environment(MockStore.self) private var store

    var body: some View {
        Section("System health") {
            ForEach(store.health) { item in
                HealthRow(item: item)
            }
        }
    }
}

struct HealthRow: View {
    let item: HealthItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        switch item.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch item.status {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        }
    }
}

#Preview {
    SettingsView()
        .environment(MockStore())
        .frame(width: 700, height: 900)
}
