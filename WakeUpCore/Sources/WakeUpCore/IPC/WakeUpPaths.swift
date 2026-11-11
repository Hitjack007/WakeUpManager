import Foundation

/// Where the scheduler keeps its files. Everything lives under the user's Application Support folder,
/// which launchd jobs are allowed to use (unlike Desktop, Documents and Downloads).
public enum WakeUpPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WakeUpManager", isDirectory: true)
    }

    public static var socketPath: String { supportDirectory.appendingPathComponent("wakeup.sock").path }
    public static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    public static var logsDirectory: URL { supportDirectory.appendingPathComponent("logs", isDirectory: true) }
}
