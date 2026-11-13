import CryptoKit
import Foundation

/// Identifies exactly which program file is running, so the app can tell when the scheduler agent is older than
/// the one now inside the app (after an update, or after the app was replaced while the agent kept running).
public enum BuildFingerprint {
    /// A short hash of the file's contents, or nil if it can't be read.
    public static func ofFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// The fingerprint of the program this process was started from.
    public static let ofThisProgram: String? = {
        let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return ofFile(at: url)
    }()
}
