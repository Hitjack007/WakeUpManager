//
//  SoftwareUpdater.swift
//  WakeUpManager
//
//  Sparkle updates, set up the same way as DynamicNotch: the feed is an appcast.xml on GitHub Pages, the
//  updates are DMGs on GitHub releases, and each one is signed with the EdDSA key whose public half is
//  SUPublicEDKey in Info.plist (release.sh signs them).
//

import Foundation
import Observation
import OSLog
import Sparkle

/// Logs what Sparkle does, so a failed update can be diagnosed from Console.
final class SparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private static let log = Logger(subsystem: "com.Hitjack007.WakeUpManager", category: "updates")

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Self.log.notice("Sparkle: no update found, \(type(of: error))")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Self.log.error("Sparkle: update cycle aborted, \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error {
            Self.log.error("Sparkle: update cycle finished with error, \(error.localizedDescription)")
        } else {
            Self.log.notice("Sparkle: update cycle finished successfully")
        }
    }
}

/// What the app shows about updates. Wraps Sparkle's standard updater, which shows its own windows.
@Observable
final class SoftwareUpdater {
    private(set) var canCheckForUpdates = false
    var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    /// Held here: the controller doesn't retain its delegate.
    private let delegate = SparkleUpdaterDelegate()
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
