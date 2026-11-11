//
//  CommandLineToolModel.swift
//  WakeUpManager
//
//  The `wakeup` command lives inside the app. Installing it puts a link to it in ~/.local/bin, so scripts
//  and agents can run plain `wakeup`. The link points into the app, so it keeps working after an update.
//

import Foundation
import Observation

@Observable
final class CommandLineToolModel {
    enum Status: Equatable {
        case notInstalled
        case installed
        /// A link exists but points somewhere else (an older copy of the app, or something that isn't ours).
        case pointsElsewhere(String)
        /// This build of the app doesn't contain the tool.
        case unavailable
    }

    private(set) var status: Status = .unavailable
    private(set) var errorMessage: String?

    private let linkURL: URL
    private let toolURL: URL

    init(
        linkURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/wakeup"),
        toolURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wakeup")
    ) {
        self.linkURL = linkURL
        self.toolURL = toolURL
        refresh()
    }

    var linkPath: String { "~/.local/bin/wakeup" }

    func refresh() {
        guard FileManager.default.isExecutableFile(atPath: toolURL.path) else {
            status = .unavailable
            return
        }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) else {
            // Nothing there, or a real file that isn't our link: leave real files alone.
            status = FileManager.default.fileExists(atPath: linkURL.path) ? .pointsElsewhere(linkURL.path) : .notInstalled
            return
        }
        status = destination == toolURL.path ? .installed : .pointsElsewhere(destination)
    }

    func install() {
        do {
            try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Replace only a link. A real file at that path is somebody's own program.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil {
                try FileManager.default.removeItem(at: linkURL)
            }
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: toolURL)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func remove() {
        do {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil {
                try FileManager.default.removeItem(at: linkURL)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
