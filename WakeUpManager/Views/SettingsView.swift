//
//  SettingsView.swift
//  WakeUpManager
//

import SwiftUI
import WakeUpSystem

struct SettingsView: View {
    @Environment(SchedulerStore.self) private var store

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    BatterySection(store: store)
                    IntensitySection()
                    TimingSection(store: store)
                    AppearanceSection()
                    UpdatesSection()
                    CommandLineToolSection()
                    ClaudeGuardSection()
                    HealthSection()
                }
                .formStyle(.grouped)
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsView()
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Battery

struct BatterySection: View {
    @Bindable var store: SchedulerStore

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
    @Bindable var store: SchedulerStore

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

// MARK: - Appearance

struct AppearanceSection: View {
    @AppStorage(AppAppearance.menuBarKey) private var showMenuBarIcon = true
    @AppStorage(AppAppearance.dockKey) private var showDockIcon = true

    var body: some View {
        Section {
            Toggle("Show in the menu bar", isOn: $showMenuBarIcon)
            Toggle("Show in the Dock", isOn: $showDockIcon)
                .onChange(of: showDockIcon) { AppAppearance.apply() }
        } header: {
            Text("Appearance")
        } footer: {
            if !showMenuBarIcon && !showDockIcon {
                Text("The app keeps running without an icon and still shows alerts. To open this window again, open WakeUp Manager from Finder or Spotlight.")
            } else {
                Text("The scheduler runs in the background either way. The menu bar item shows the next wake and a quick way to check for updates.")
            }
        }
    }
}

// MARK: - Software updates

struct UpdatesSection: View {
    @Environment(SoftwareUpdater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section {
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("Automatically download updates", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        } header: {
            Text("Software updates")
        } footer: {
            Text("Updates come from this app's GitHub releases and are checked against a signature before they are installed.")
        }
    }
}

// MARK: - Command line tool

struct CommandLineToolSection: View {
    @Environment(CommandLineToolModel.self) private var tool

    var body: some View {
        Section {
            LabeledContent("wakeup command") {
                switch tool.status {
                case .installed: Button("Remove") { tool.remove() }
                case .notInstalled, .pointsElsewhere: Button("Install") { tool.install() }
                case .unavailable: Text("Not in this build").foregroundStyle(.secondary)
                }
            }
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            if let message = tool.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Command line")
        } footer: {
            Text("Scripts and agents use this to ask the scheduler for wakes. Make sure ~/.local/bin is on your PATH.")
        }
        .task { tool.refresh() }
    }

    private var statusText: LocalizedStringKey {
        switch tool.status {
        case .installed: "Installed as \(tool.linkPath)."
        case .notInstalled: "Not installed. Adds a link at \(tool.linkPath) to the copy inside this app."
        case .pointsElsewhere(let path): "\(tool.linkPath) already exists and points to \(path). Installing replaces a link, never a real file."
        case .unavailable: "This build of the app doesn't contain the command yet."
        }
    }
}

// MARK: - Claude Code guard

struct ClaudeGuardSection: View {
    @Environment(ClaudeGuardModel.self) private var guardModel
    @State private var confirmingInstall = false
    @State private var devModeMinutes = 60

    var body: some View {
        Section {
            LabeledContent("Claude Code guard") {
                switch guardModel.status {
                case .installed:
                    Button("Remove") { guardModel.remove() }
                case .notInstalled:
                    Button("Install...") { confirmingInstall = true }
                case .needsRepair:
                    HStack {
                        Button("Repair") { guardModel.install() }
                        Button("Remove") { guardModel.remove() }
                    }
                }
            }
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            if let message = guardModel.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("What will be added") {
                MonospacedLine(text: "hooks.PreToolUse (matcher Bash): refuse pmset schedule and pmset repeat, and point the agent to the guide")
            }
            if guardModel.status == .installed {
                Toggle("Developer mode", isOn: developerModeBinding)
                if let until = guardModel.developerModeUntil {
                    Text("Wake commands are allowed until \(until, format: .dateTime.hour().minute()).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Turns off after", selection: $devModeMinutes) {
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("4 hours").tag(240)
                    }
                }
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("Installing edits another tool's settings file. A backup is made first, and Remove only takes out what was added.")
        }
        .confirmationDialog("Edit Claude Code's settings?", isPresented: $confirmingInstall) {
            Button("Install") { guardModel.install() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This adds one hook to \(guardModel.settingsPath) after backing it up. Nothing else in the file is changed.")
        }
        .task { guardModel.refresh() }
    }

    private var statusText: LocalizedStringKey {
        switch guardModel.status {
        case .installed: "Installed in \(guardModel.settingsPath). Claude Code is told to use the scheduler instead of booking wakes itself."
        case .notInstalled: "Not installed. Claude Code could book wakes on its own."
        case .needsRepair: "Partly installed. The hook or its script is missing or out of date."
        }
    }

    private var developerModeBinding: Binding<Bool> {
        Binding(
            get: { guardModel.developerModeUntil != nil },
            set: { guardModel.setDeveloperMode(minutes: $0 ? devModeMinutes : nil) })
    }
}

// MARK: - Health

struct HealthSection: View {
    @Environment(SchedulerStore.self) private var store

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
        .environment(SchedulerStore())
        .environment(PermissionsModel())
        .environment(ClaudeGuardModel())
        .environment(CommandLineToolModel())
        .environment(SoftwareUpdater())
        .frame(width: 700, height: 900)
}
