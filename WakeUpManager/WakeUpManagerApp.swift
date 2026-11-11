//
//  WakeUpManagerApp.swift
//  WakeUpManager
//
//  Created by Mark Greene on 11/11/2026.
//

import SwiftUI

@main
struct WakeUpManagerApp: App {
    @State private var store = WakeUpManagerApp.makeLiveStore()
    @State private var permissions = PermissionsModel()
    @State private var claudeGuard = ClaudeGuardModel()
    @State private var commandLineTool = CommandLineToolModel()

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
        }

        MenuBarExtra("WakeUp Manager", systemImage: "alarm") {
            MenuBarContent()
                .environment(store)
        }
    }
}
