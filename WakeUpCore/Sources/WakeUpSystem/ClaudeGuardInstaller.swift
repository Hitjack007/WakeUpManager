import Foundation
import WakeUpCore

/// Installs and removes the Claude Code guard: a `PreToolUse` hook in Claude Code's settings that refuses
/// commands which book wakes (`pmset schedule`, `pmset repeat`) and tells the agent to use the scheduler.
///
/// The app calls this when the user switches the guard on. Nothing else edits the settings file.
/// Only the hook entry the installer added is ever touched, and every change is preceded by a backup.
public struct ClaudeGuardInstaller {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// The settings entry or the script is missing or out of date.
        case needsRepair
    }

    public struct InstallError: Error, LocalizedError, Equatable {
        public var errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    public var settingsURL: URL
    public var supportDirectory: URL
    /// The `wakeup` tool, named in the agent guide. If it can't be placed on a path the guide says `wakeup`.
    public var cliPath: String?

    public init(
        settingsURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json"),
        supportDirectory: URL = WakeUpPaths.supportDirectory,
        cliPath: String? = nil
    ) {
        self.settingsURL = settingsURL
        self.supportDirectory = supportDirectory
        self.cliPath = cliPath
    }

    public var scriptURL: URL { supportDirectory.appendingPathComponent("claude-guard.sh") }
    public var guideURL: URL { supportDirectory.appendingPathComponent("agent-guide.md") }
    public var devModeURL: URL { supportDirectory.appendingPathComponent("dev-mode-until") }

    /// What goes in the settings file's `command`. Quoted, because the path has a space in it.
    var hookCommand: String { "'\(scriptURL.path)'" }

    /// The scheduler's hook entries are recognised by the script name in their command.
    private static func isOurs(_ hook: Any) -> Bool {
        guard let hook = hook as? [String: Any], let command = hook["command"] as? String else { return false }
        return command.contains("claude-guard.sh")
    }

    // MARK: Status

    public func status() -> Status {
        let settings = (try? loadSettings()) ?? [:]
        let hasEntry = ourEntries(in: settings) > 0
        let hasScript = FileManager.default.isExecutableFile(atPath: scriptURL.path)
            && (try? String(contentsOf: scriptURL, encoding: .utf8)) == scriptText
        switch (hasEntry, hasScript) {
        case (false, false): return .notInstalled
        case (true, true): return ourEntries(in: settings) == 1 ? .installed : .needsRepair
        default: return .needsRepair
        }
    }

    // MARK: Install and remove

    public func install() throws {
        var settings = try loadSettings()
        try backUpSettings()

        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try scriptText.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try guideText.write(to: guideURL, atomically: true, encoding: .utf8)

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
        removeOurHooks(from: &groups)
        groups.append([
            "matcher": "Bash",
            "hooks": [["type": "command", "command": hookCommand]],
        ])
        hooks["PreToolUse"] = groups
        settings["hooks"] = hooks
        try saveSettings(settings)
    }

    public func remove() throws {
        var settings = try loadSettings()
        if ourEntries(in: settings) > 0 {
            try backUpSettings()
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            var groups = hooks["PreToolUse"] as? [[String: Any]] ?? []
            removeOurHooks(from: &groups)
            // Only tidy up what the removal emptied. Other hooks and keys stay as they were.
            if groups.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = groups }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
            try saveSettings(settings)
        }
        for url in [scriptURL, guideURL, devModeURL] { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Developer mode

    /// Lets wake commands through until `date`. `nil` turns it off. The script reads the file at every
    /// command, so an agent can't switch this on: only the app writes it.
    public func setDeveloperMode(until date: Date?) throws {
        guard let date else {
            try? FileManager.default.removeItem(at: devModeURL)
            return
        }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try String(Int(date.timeIntervalSince1970)).write(to: devModeURL, atomically: true, encoding: .utf8)
    }

    public func developerModeExpiry(now: Date = Date()) -> Date? {
        guard let text = try? String(contentsOf: devModeURL, encoding: .utf8),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return date > now ? date : nil
    }

    // MARK: Settings file

    private func loadSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let settings = object as? [String: Any] else {
            // Never overwrite a file we can't read: it may be the user's only copy of their settings.
            throw InstallError("Claude Code's settings file isn't valid JSON, so it was left alone.")
        }
        return settings
    }

    private func saveSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func backUpSettings() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = settingsURL.appendingPathExtension("wakeup-backup-\(formatter.string(from: Date()))")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: settingsURL, to: backup)
    }

    private func ourEntries(in settings: [String: Any]) -> Int {
        let groups = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
        return groups.reduce(0) { $0 + (($1["hooks"] as? [Any]) ?? []).filter(Self.isOurs).count }
    }

    private func removeOurHooks(from groups: inout [[String: Any]]) {
        groups = groups.compactMap { group in
            guard let hooks = group["hooks"] as? [Any] else { return group }
            let kept = hooks.filter { !Self.isOurs($0) }
            if kept.count == hooks.count { return group }
            if kept.isEmpty { return nil }
            var changed = group
            changed["hooks"] = kept
            return changed
        }
    }

    // MARK: The script and the guide

    /// What the hook runs. It reads the tool call Claude Code passes on standard input and exits with 2
    /// (which blocks the call and shows the message to the agent) if it books a wake.
    var scriptText: String {
        """
        #!/bin/sh
        # Installed by WakeUp Manager. Reinstalling from the app replaces this file.
        input=$(cat)

        # Developer mode: the app writes the time (seconds since 1970) until which wake commands are allowed.
        if [ -f '\(devModeURL.path)' ]; then
          until=$(cat '\(devModeURL.path)' 2>/dev/null)
          case "$until" in
            ''|*[!0-9]*) ;;
            *) [ "$(date +%s)" -lt "$until" ] && exit 0 ;;
          esac
        fi

        if printf '%s' "$input" | grep -Eq 'pmset[^|;&]*[[:space:]](schedule|repeat)([[:space:]"\\\\]|$)|IOPMSchedulePowerEvent'; then
          cat >&2 <<'MESSAGE'
        Blocked by WakeUp Manager: this Mac's wakes are booked only by the WakeUp Manager scheduler.
        Do not run pmset schedule or pmset repeat, and do not write your own wake timer.
        Ask the scheduler instead, with the wakeup tool. Read this first: \(guideURL.path)
        Example: wakeup request --name "My job" --at 2026-11-12T07:00 --estimate 30 --exec /path/to/script
        MESSAGE
          exit 2
        fi
        exit 0

        """
    }

    var guideText: String {
        let tool = cliPath ?? "wakeup"
        return """
        # Waking this Mac with WakeUp Manager

        Only the WakeUp Manager scheduler may wake this Mac. Do not run `pmset schedule` or `pmset repeat`,
        do not call `IOPMSchedulePowerEvent`, and do not build your own wake timer. Those are blocked.
        Ask the scheduler to wake the Mac and start your job instead.

        ## How it works

        1. You file a request with `\(tool) request` and your job goes dormant. Nothing of yours needs to keep running.
        2. The scheduler wakes the Mac shortly before the start time and holds it awake.
        3. It starts your job at the requested time. Inside the job, `WAKEUP_EXECUTION_ID` and `WAKEUP_SOCKET` are set.
        4. When your job finishes (and it asks to be told, see `--reported-by`), it runs `\(tool) done`.
        5. The scheduler records the result and lets the Mac sleep.

        ## Asking for a wake

        ```
        \(tool) request --name "Night shift" --at 2026-11-12T01:13 --estimate 60 \\
            --exec /Users/me/.local/bin/claude --cwd /Users/me/Project -- -p "resume"
        ```

        - Times are local wall-clock times. A job at 07:00 stays at 07:00 when daylight saving changes.
        - `--estimate` is minutes, for planning only. A job that overruns is not killed. The user is told.
        - `--cpu` and `--gpu` are the percentages you expect to use. The scheduler works out how heavy the job is.
        - `--repeat daily|weekly` (with `--every N`, `--days mon,thu`, `--until`) makes the job recurring.
        - Use `--app BUNDLE-ID` instead of `--exec` to open a macOS app.
        - `--job-id` names the job. Asking again with the same id replaces the earlier request.
        - The client is the folder you run this from (or `--client-path`). The user approves each client once.

        ## Telling the scheduler you are done

        ```
        \(tool) done --status success --message "4 chunks done"
        \(tool) done --status partial --reschedule-at 2026-11-13T01:13:00+13:00 --reschedule-minutes 60
        ```

        ## Other commands

        - `\(tool) status` shows what is scheduled and running.
        - `\(tool) cancel --job-id ID` removes a job.
        - `\(tool) help` lists every option.

        ## Exit codes

        0 done or authorised. 1 rejected. 2 the scheduler can't be reached. 3 the scheduler refused.
        10 waiting for the user to approve this client. 11 an overlap is waiting for the user's decision.
        64 the command was used wrongly.
        """
    }
}
