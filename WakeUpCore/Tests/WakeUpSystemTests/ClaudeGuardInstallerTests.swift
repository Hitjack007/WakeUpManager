import Foundation
import Testing
@testable import WakeUpSystem

/// A guard installer pointed at a throwaway folder, never at the real `~/.claude`.
private struct Sandbox {
    let root: URL
    let installer: ClaudeGuardInstaller

    init(settings: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settingsURL = root.appendingPathComponent("claude/settings.json")
        if let settings {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try settings.write(to: settingsURL, atomically: true, encoding: .utf8)
        }
        installer = ClaudeGuardInstaller(
            settingsURL: settingsURL, supportDirectory: root.appendingPathComponent("Support With Space"))
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func settings() throws -> [String: Any] {
        let data = try Data(contentsOf: installer.settingsURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    var backups: [String] {
        let folder = installer.settingsURL.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.contains("wakeup-backup") }
    }

    /// Runs the hook script the way Claude Code does: a tool call as JSON on standard input.
    func runHook(command: String) throws -> (status: Int32, stderr: String) {
        let call = try JSONSerialization.data(withJSONObject: [
            "tool_name": "Bash", "tool_input": ["command": command],
        ])
        let process = Process()
        process.executableURL = installer.scriptURL
        let input = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardError = error
        process.standardOutput = Pipe()
        try process.run()
        input.fileHandleForWriting.write(call)
        try input.fileHandleForWriting.close()
        let message = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: message, as: UTF8.self))
    }
}

private let otherSettings = """
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Edit", "hooks": [ { "type": "command", "command": "/usr/local/bin/lint" } ] }
    ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "say done" } ] } ]
  }
}
"""

@Suite("Claude Code guard installer")
struct ClaudeGuardInstallerTests {
    @Test func installsIntoAMissingSettingsFile() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        #expect(box.installer.status() == .notInstalled)

        try box.installer.install()

        #expect(box.installer.status() == .installed)
        let groups = try #require((try box.settings()["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] as? String == "Bash")
        #expect(FileManager.default.isExecutableFile(atPath: box.installer.scriptURL.path))
        #expect(FileManager.default.fileExists(atPath: box.installer.guideURL.path))
    }

    @Test func keepsEverythingElseAndMakesABackup() throws {
        let box = try Sandbox(settings: otherSettings)
        defer { box.cleanUp() }

        try box.installer.install()

        let settings = try box.settings()
        #expect(settings["model"] as? String == "opus")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(hooks["Stop"] != nil)
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 2)
        #expect(box.backups.count == 1)
    }

    @Test func installingAgainDoesNotAddASecondEntry() throws {
        let box = try Sandbox(settings: otherSettings)
        defer { box.cleanUp() }

        try box.installer.install()
        try box.installer.install()

        let groups = try #require((try box.settings()["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(groups.count == 2)
        #expect(box.installer.status() == .installed)
    }

    @Test func removeTakesOutOnlyWhatWasAdded() throws {
        let box = try Sandbox(settings: otherSettings)
        defer { box.cleanUp() }
        try box.installer.install()

        try box.installer.remove()

        #expect(box.installer.status() == .notInstalled)
        let hooks = try #require(try box.settings()["hooks"] as? [String: Any])
        let groups = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(groups.count == 1)
        #expect(groups[0]["matcher"] as? String == "Edit")
        #expect(hooks["Stop"] != nil)
        #expect(!FileManager.default.fileExists(atPath: box.installer.scriptURL.path))
    }

    @Test func removeTidiesUpWhatItEmptied() throws {
        let box = try Sandbox(settings: "{\"model\": \"opus\"}")
        defer { box.cleanUp() }
        try box.installer.install()

        try box.installer.remove()

        let settings = try box.settings()
        #expect(settings["hooks"] == nil)
        #expect(settings["model"] as? String == "opus")
    }

    @Test func aSettingsFileItCannotReadIsLeftAlone() throws {
        let box = try Sandbox(settings: "{ not json")
        defer { box.cleanUp() }

        #expect(throws: ClaudeGuardInstaller.InstallError.self) { try box.installer.install() }
        #expect(try String(contentsOf: box.installer.settingsURL, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: box.installer.scriptURL.path))
    }

    @Test func aDeletedScriptNeedsRepair() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try box.installer.install()
        try FileManager.default.removeItem(at: box.installer.scriptURL)
        #expect(box.installer.status() == .needsRepair)

        try box.installer.install()
        #expect(box.installer.status() == .installed)
    }
}

@Suite("Claude Code guard script")
struct ClaudeGuardScriptTests {
    private func installed() throws -> Sandbox {
        let box = try Sandbox()
        try box.installer.install()
        return box
    }

    @Test func blocksCommandsThatBookWakes() throws {
        let box = try installed()
        defer { box.cleanUp() }
        for command in [
            "sudo pmset schedule wake \"11/12/26 06:55:00\" mine",
            "sudo -n /usr/bin/pmset schedule cancel wake \"11/12/26 06:55:00\"",
            "pmset repeat wakeorpoweron MTWRF 07:00:00",
            "cd /tmp && sudo pmset schedule wake x",
        ] {
            let result = try box.runHook(command: command)
            #expect(result.status == 2, "should block: \(command)")
            #expect(result.stderr.contains("wakeup request"))
            #expect(result.stderr.contains(box.installer.guideURL.path))
        }
    }

    @Test func allowsEverythingElse() throws {
        let box = try installed()
        defer { box.cleanUp() }
        for command in ["pmset -g sched", "pmset -g assertions", "caffeinate -ims -w 123", "ls -la", "wakeup status"] {
            #expect(try box.runHook(command: command).status == 0, "should allow: \(command)")
        }
    }

    @Test func developerModeLetsWakeCommandsThroughUntilItExpires() throws {
        let box = try installed()
        defer { box.cleanUp() }
        let command = "sudo pmset schedule wake x"

        try box.installer.setDeveloperMode(until: Date().addingTimeInterval(600))
        #expect(try box.runHook(command: command).status == 0)
        #expect(box.installer.developerModeExpiry() != nil)

        try box.installer.setDeveloperMode(until: Date().addingTimeInterval(-5))
        #expect(try box.runHook(command: command).status == 2)
        #expect(box.installer.developerModeExpiry() == nil)

        try box.installer.setDeveloperMode(until: Date().addingTimeInterval(600))
        try box.installer.setDeveloperMode(until: nil)
        #expect(try box.runHook(command: command).status == 2)
    }

    @Test func aGarbledDeveloperModeFileDoesNotOpenTheGuard() throws {
        let box = try installed()
        defer { box.cleanUp() }
        try "soon".write(to: box.installer.devModeURL, atomically: true, encoding: .utf8)
        #expect(try box.runHook(command: "pmset schedule wake x").status == 2)
    }
}
