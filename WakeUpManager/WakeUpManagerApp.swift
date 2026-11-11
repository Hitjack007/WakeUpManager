//
//  WakeUpManagerApp.swift
//  WakeUpManager
//
//  Created by Mark Greene on 11/11/2026.
//

import OSLog
import SwiftUI

/// Whether the app shows a menu bar icon and a Dock icon. The scheduler itself runs in the background agent,
/// so the app can run with neither: it then only shows alerts. Opening the app again brings the window back.
enum AppAppearance {
    static let menuBarKey = "showMenuBarIcon"
    static let dockKey = "showDockIcon"

    /// - Parameter keepWindowsInFront: after the user changes the setting. Switching policy makes macOS
    ///   deactivate the app and hide its windows, so the app brings itself back to the front.
    static func apply(keepWindowsInFront: Bool = false) {
        let showDock = UserDefaults.standard.object(forKey: dockKey) as? Bool ?? true
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        if !NSApp.setActivationPolicy(policy) {
            Logger(subsystem: "com.Hitjack007.WakeUpManager", category: "appearance")
                .error("macOS refused to change the activation policy to \(showDock ? "regular" : "accessory")")
        }
        guard keepWindowsInFront else { return }
        // The Dock icon only appears (or goes) once the change has settled and the app is activated again,
        // so activate on the next turns of the run loop rather than straight away.
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if showDock { _ = NSApp.setActivationPolicy(.regular) }
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate()
                for window in NSApp.windows where window.canBecomeMain && !window.isMiniaturized {
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()
    }
}

@main
struct WakeUpManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppAppearance.menuBarKey) private var showMenuBarIcon = true
    @State private var store = WakeUpManagerApp.makeLiveStore()
    @State private var permissions = PermissionsModel()
    @State private var claudeGuard = ClaudeGuardModel()
    @State private var commandLineTool = CommandLineToolModel()
    @State private var softwareUpdater = SoftwareUpdater()

    /// The screens show what the scheduler agent reports, not dummy data.
    private static func makeLiveStore() -> SchedulerStore {
        let store = SchedulerStore(sampleData: false)
        store.link = SchedulerLink()
        // Lives as long as the app does, so notices still arrive with the window closed.
        Task {
            let notifier = SystemNotifier()
            await store.runLive { notices in notices.forEach(notifier.notify) }
        }
        return store
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(permissions)
                .environment(claudeGuard)
                .environment(commandLineTool)
                .environment(softwareUpdater)
        }

        MenuBarExtra("WakeUp Manager", systemImage: "alarm", isInserted: $showMenuBarIcon) {
            MenuBarContent()
                .environment(store)
                .environment(softwareUpdater)
        }
    }
}
