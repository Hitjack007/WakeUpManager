//
//  PermissionsModel.swift
//  WakeUpManager
//
//  What the app needs macOS's permission for, and how to ask. The prompts come from macOS itself:
//  notifications show the system alert, and the two background services are registered with
//  SMAppService, which adds them to System Settings > General > Login Items for the user to switch on.
//  Same shape as DynamicNotch's PermissionRequester: one kind per permission, one request call each.
//

import AppKit
import Observation
import OSLog
import ServiceManagement
import UserNotifications

enum PermissionKind: String, CaseIterable, Identifiable {
    case notifications
    case openAtLogin
    case schedulerAgent
    case wakeHelper

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .notifications: "Notifications"
        case .openAtLogin: "Open at login"
        case .schedulerAgent: "Background scheduler"
        case .wakeHelper: "Wake helper"
        }
    }

    var symbol: String {
        switch self {
        case .notifications: "bell.badge"
        case .openAtLogin: "menubar.rectangle"
        case .schedulerAgent: "alarm"
        case .wakeHelper: "powersleep"
        }
    }

    /// What it is for, in plain words.
    var summary: LocalizedStringResource {
        switch self {
        case .notifications:
            "Tells you when a job runs past its estimate, a run is skipped, another app books a wake, or a new app asks to be approved."
        case .openAtLogin:
            "Starts this app in the menu bar when you log in, so alerts reach you even when its window is closed."
        case .schedulerAgent:
            "Keeps the scheduler running in your login session so it can start jobs and hold the Mac awake while they run."
        case .wakeHelper:
            "Books and cancels the Mac's wake times. macOS only lets a root process do that, so it's a small helper inside this app."
        }
    }

    /// The reassurance shown under the description.
    var privacyNote: LocalizedStringResource {
        switch self {
        case .notifications:
            "Only this app's own alerts. Nothing is read from other apps."
        case .openAtLogin:
            "Only the menu bar item and alerts. Switch it off any time in System Settings > Login Items."
        case .schedulerAgent:
            "Runs as you, not as an administrator. Switch it off any time in System Settings > Login Items."
        case .wakeHelper:
            "It can only book and cancel wakes. macOS will ask for your approval in System Settings."
        }
    }

    /// The button on the card.
    var allowTitle: LocalizedStringResource {
        switch self {
        case .notifications: "Allow Notifications"
        case .openAtLogin, .schedulerAgent, .wakeHelper: "Allow in Login Items"
        }
    }
}

enum PermissionStatus: Equatable {
    /// macOS hasn't been asked yet.
    case notAsked
    case allowed
    /// Registered, but the user still has to switch it on in System Settings.
    case needsApproval
    /// The user said no. Only System Settings can change that.
    case denied
    /// Can't be asked for, with the reason (for example, this build doesn't contain the helper yet).
    case unavailable(String)

    var isAllowed: Bool { self == .allowed }
}

@Observable
final class PermissionsModel {
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    /// The permission whose macOS prompt is open right now.
    private(set) var asking: PermissionKind?

    private static let log = Logger(subsystem: "com.Hitjack007.WakeUpManager", category: "permissions")

    /// The property lists inside the app bundle (Contents/Library/LaunchAgents and LaunchDaemons).
    static let agentPlistName = "com.wakeupmanager.agent.plist"
    static let helperPlistName = "com.wakeupmanager.helper.plist"

    func status(of kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notAsked
    }

    var allAllowed: Bool { PermissionKind.allCases.allSatisfy { status(of: $0).isAllowed } }

    /// Permissions still worth asking about, in order.
    var outstanding: [PermissionKind] {
        PermissionKind.allCases.filter {
            switch status(of: $0) {
            case .notAsked, .needsApproval: true
            case .allowed, .denied, .unavailable: false
            }
        }
    }

    // MARK: Reading the current state

    func refresh() async {
        for kind in PermissionKind.allCases {
            statuses[kind] = await currentStatus(of: kind)
        }
    }

    private func currentStatus(of kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return .notAsked
            case .denied: return .denied
            default: return .allowed
            }
        case .openAtLogin:
            return status(of: SMAppService.mainApp, kind: kind, bundledFile: nil)
        case .schedulerAgent:
            return status(of: SMAppService.agent(plistName: Self.agentPlistName), kind: kind,
                          bundledFile: "Contents/Library/LaunchAgents/\(Self.agentPlistName)")
        case .wakeHelper:
            return status(of: SMAppService.daemon(plistName: Self.helperPlistName), kind: kind,
                          bundledFile: "Contents/Library/LaunchDaemons/\(Self.helperPlistName)")
        }
    }

    /// Why macOS refused to register a service, kept so the row can show it.
    private var registrationErrors: [PermissionKind: String] = [:]

    /// macOS answers `notFound` for a service it has no record of yet, which is every service before its first
    /// `register()`. So `notFound` only means "unavailable" if the file isn't in the app, or registering was tried and failed.
    private func status(of service: SMAppService, kind: PermissionKind, bundledFile: String?) -> PermissionStatus {
        switch service.status {
        case .enabled: return .allowed
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .notAsked
        case .notFound:
            if let reason = registrationErrors[kind] { return .unavailable(reason) }
            if let bundledFile, !FileManager.default.fileExists(
                atPath: Bundle.main.bundleURL.appending(path: bundledFile).path) {
                return .unavailable("This copy of the app doesn't contain the scheduler programs. Rebuild it so the \"Run Script\" build phase runs.")
            }
            return .notAsked
        @unknown default: return .unavailable("macOS reported a state this version doesn't know.")
        }
    }

    // MARK: Asking

    /// Triggers the macOS prompt for `kind`, then re-reads the state.
    func request(_ kind: PermissionKind) async {
        asking = kind
        defer { asking = nil }

        switch kind {
        case .notifications:
            let current = await currentStatus(of: .notifications)
            if current == .denied {
                openSystemSettings(for: .notifications)
            } else {
                do {
                    let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    Self.log.notice("Permission request (notifications): granted=\(granted)")
                } catch {
                    Self.log.error("Permission request (notifications) threw, \(type(of: error))")
                }
            }

        case .openAtLogin:
            register(SMAppService.mainApp, kind: kind, name: "open at login")

        case .schedulerAgent:
            register(SMAppService.agent(plistName: Self.agentPlistName), kind: kind, name: "scheduler agent")

        case .wakeHelper:
            register(SMAppService.daemon(plistName: Self.helperPlistName), kind: kind, name: "wake helper")
        }
        await refresh()
    }

    /// Registering adds the service to Login Items. If macOS wants the user's say-so, send them there.
    private func register(_ service: SMAppService, kind: PermissionKind, name: String) {
        registrationErrors[kind] = nil
        do {
            try service.register()
        } catch {
            // `requiresApproval` also arrives as an error on some versions, so look at the state after.
            Self.log.notice("Registering the \(name) reported: \(error.localizedDescription)")
            if service.status == .notFound { registrationErrors[kind] = error.localizedDescription }
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        Self.log.notice("Permission request (\(name)): status=\(String(describing: service.status))")
    }

    /// For a permission the user has turned off: the page in System Settings that changes it.
    func openSystemSettings(for kind: PermissionKind) {
        switch kind {
        case .notifications:
            let bundleId = Bundle.main.bundleIdentifier ?? ""
            let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)")
            if let url { NSWorkspace.shared.open(url) }
        case .openAtLogin, .schedulerAgent, .wakeHelper:
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
