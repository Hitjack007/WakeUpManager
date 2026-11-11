import Foundation

/// What the root helper offers. The agent (and only the agent and the app) calls it over XPC.
///
/// Every method answers with `nil` on success or a message saying why it failed. The helper does the one
/// thing that needs root: booking and cancelling wakes with `pmset schedule`.
@objc public protocol WakeHelperProtocol {
    func bookWake(at date: Date, owner: String, reply: @escaping (String?) -> Void)
    func cancelEvent(kind: String, at date: Date, owner: String, reply: @escaping (String?) -> Void)
    /// Answers with the helper's version, so the app can tell the helper is alive and current.
    func version(reply: @escaping (String) -> Void)
}

public enum WakeHelperConstants {
    /// The Mach service the helper listens on. Must match `MachServices` in the daemon's property list.
    public static let machServiceName = "com.wakeupmanager.helper"
    public static let version = "1"
    /// Code signing identifiers of the programs that may talk to the helper.
    public static let appIdentifier = "com.Hitjack007.WakeUpManager"
    public static let agentIdentifier = "com.Hitjack007.WakeUpManager.agent"
    public static let helperIdentifier = "com.Hitjack007.WakeUpManager.helper"

    /// The signing requirement a peer must meet: one of the given identifiers, signed by the given team.
    public static func requirement(identifiers: [String], teamIdentifier: String) -> String {
        let ids = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and (\(ids)) and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
