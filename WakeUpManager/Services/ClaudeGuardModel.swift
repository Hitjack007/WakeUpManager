//
//  ClaudeGuardModel.swift
//  WakeUpManager
//
//  The app's side of the Claude Code guard. The installer does the work; this only holds what the
//  Settings screen shows and reports a failure instead of hiding it.
//

import Foundation
import Observation
import WakeUpSystem

@Observable
final class ClaudeGuardModel {
    private(set) var status: ClaudeGuardInstaller.Status
    private(set) var developerModeUntil: Date?
    /// Set when the last install, removal or mode change failed. Cleared by the next success.
    private(set) var errorMessage: String?

    private let installer: ClaudeGuardInstaller

    init(installer: ClaudeGuardInstaller = ClaudeGuardInstaller()) {
        self.installer = installer
        status = installer.status()
        developerModeUntil = installer.developerModeExpiry()
    }

    var settingsPath: String { "~/.claude/settings.json" }

    func refresh() {
        status = installer.status()
        developerModeUntil = installer.developerModeExpiry()
    }

    func install() {
        perform { try installer.install() }
    }

    func remove() {
        perform {
            try installer.setDeveloperMode(until: nil)
            try installer.remove()
        }
    }

    /// Allows wake commands for `minutes`, or turns developer mode off when `minutes` is `nil`.
    func setDeveloperMode(minutes: Int?) {
        perform {
            try installer.setDeveloperMode(until: minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) })
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
