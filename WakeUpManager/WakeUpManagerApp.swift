//
//  WakeUpManagerApp.swift
//  WakeUpManager
//
//  Created by Mark Greene on 11/11/2026.
//

import OSLog
import SwiftUI

/// When the app has a Dock icon.
enum DockIconMode: String, CaseIterable, Identifiable {
    case always
    /// The icon is there while the window is open and goes when it is closed (the way DynamicNotch behaves).
    case whileWindowOpen
    case never

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .always: "Always"
        case .whileWindowOpen: "Only while the window is open"
        case .never: "Never"
        }
    }
}

/// Whether the app shows a menu bar icon and a Dock icon. The scheduler itself runs in the background agent,
/// so the app can run with neither: it then only shows alerts. The menu bar item, or opening the app again
/// from Finder or Spotlight, brings the window back.
enum AppAppearance {
    static let menuBarKey = "showMenuBarIcon"
    static let dockKey = "dockIconMode"
    private static let log = Logger(subsystem: "com.Hitjack007.WakeUpManager", category: "appearance")

    static var dockMode: DockIconMode {
        DockIconMode(rawValue: UserDefaults.standard.string(forKey: dockKey) ?? "") ?? .whileWindowOpen
    }

    /// Whether a real window (not the menu bar popover or a panel) is on screen.
    static func hasOpenWindow(excluding closing: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Puts the Dock icon where the setting says it should be.
    /// - Parameters:
    ///   - closing: a window that is about to close, which no longer counts as open.
    ///   - keepWindowsInFront: after the user changes the setting. Switching policy makes macOS deactivate
    ///     the app and hide its windows, so the app brings itself back to the front.
    static func apply(closing: NSWindow? = nil, keepWindowsInFront: Bool = false) {
        let wantsDock: Bool
        switch dockMode {
        case .always: wantsDock = true
        case .never: wantsDock = false
        case .whileWindowOpen: wantsDock = hasOpenWindow(excluding: closing)
        }
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy, !NSApp.setActivationPolicy(policy) {
            log.error("macOS refused to change the activation policy to \(wantsDock ? "regular" : "accessory")")
        }
        guard keepWindowsInFront else { return }
        // The Dock icon only appears (or goes) once the change has settled and the app is activated again,
        // so activate on the next turns of the run loop rather than straight away.
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if wantsDock { _ = NSApp.setActivationPolicy(.regular) }
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
    private var observers: [any NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.apply()

        // A window opening brings the Dock icon, and closing the last one takes it away.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            AppAppearance.apply()
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            AppAppearance.apply(closing: note.object as? NSWindow)
        })
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
        WindowGroup(id: "main") {
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
