//
//  WakeUpManagerApp.swift
//  WakeUpManager
//
//  Created by Mark Greene on 11/11/2026.
//

import SwiftUI

@main
struct WakeUpManagerApp: App {
    @State private var store = MockStore()
    @State private var permissions = PermissionsModel()
    @State private var claudeGuard = ClaudeGuardModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(permissions)
                .environment(claudeGuard)
        }

        MenuBarExtra("WakeUp Manager", systemImage: "alarm") {
            MenuBarContent()
                .environment(store)
        }
    }
}
