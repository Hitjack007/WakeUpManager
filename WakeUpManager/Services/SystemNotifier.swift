//
//  SystemNotifier.swift
//  WakeUpManager
//
//  Shows the scheduler's notices as macOS notifications. It never asks for permission itself: that is
//  the Permissions tab's job, so a notice raised before the user has allowed notifications is dropped
//  here (it still appears in the Alerts screen).
//

import UserNotifications
import WakeUpCore

struct SystemNotifier: UserNotifier {
    func notify(_ notice: Notice) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.detail
            content.sound = .default
            // Reusing the notice id means showing it again replaces the banner instead of stacking another.
            let request = UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
