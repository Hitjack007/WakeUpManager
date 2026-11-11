import Foundation

/// Finds out where a process came from. The real one reads the process table; tests use a fake.
public protocol ProcessInspecting {
    /// The executable path and working directory of the process and each of its ancestors, nearest first.
    func locations(ofProcess pid: Int32) -> [String]
    /// The executable path of just that process.
    func executablePath(ofProcess pid: Int32) -> String?
}

/// Checks who is really on the other end of the socket.
///
/// A client names its location in the request (an app bundle or a project folder). The scheduler believes
/// it only if the connecting process, or one of its ancestors, runs from or sits inside that location.
/// This is for keeping honest software honest on a personal Mac, not a defence against a hostile one.
public struct LocationVerifier {
    public var inspector: any ProcessInspecting

    public init(inspector: any ProcessInspecting) {
        self.inspector = inspector
    }

    /// Whether the process (or an ancestor) is inside `claimedPath`.
    public func verifies(claimedPath: String, peerProcess pid: Int32) -> Bool {
        guard Self.isPlausibleLocation(claimedPath) else { return false }
        return inspector.locations(ofProcess: pid).contains { Self.path($0, isInside: claimedPath) }
    }

    /// Whether the process's own executable is inside one of the trusted locations (the app itself).
    public func isTrusted(peerProcess pid: Int32, trustedPaths: [String]) -> Bool {
        guard let executable = inspector.executablePath(ofProcess: pid) else { return false }
        return trustedPaths.contains { Self.isPlausibleLocation($0) && Self.path(executable, isInside: $0) }
    }

    /// A location must be absolute and at least two components deep, so `/` and `/Users` can't be claimed.
    static func isPlausibleLocation(_ path: String) -> Bool {
        path.hasPrefix("/") && path.split(separator: "/").count >= 2
    }

    static func path(_ path: String, isInside root: String) -> Bool {
        let path = canonicalPath(path)
        let root = canonicalPath(root)
        return path == root || path.hasPrefix(root + "/")
    }

    /// One spelling for a location, so `/tmp/x`, `/private/tmp/x/` and `/tmp/a/../x` are the same client.
    /// Used for every client path the scheduler stores or compares.
    public static func canonicalPath(_ path: String) -> String {
        var result = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        // Foundation drops the /private prefix that the process table keeps; make both sides the same.
        if result.hasPrefix("/private/") { result.removeFirst("/private".count) }
        return result
    }
}
