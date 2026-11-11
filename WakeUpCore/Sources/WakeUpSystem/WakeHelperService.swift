import Foundation
import WakeUpCore

/// The helper's side: checks each request and runs `pmset schedule` as root.
///
/// The helper is deliberately narrow. It books and cancels wake events and nothing else, it refuses
/// anything macOS owns (`com.apple.` owners), and it checks every value before it reaches `pmset`.
public final class WakeHelperService: NSObject, WakeHelperProtocol {
    public static let wakeKinds: Set<String> = ["wake", "poweron", "wakepoweron"]
    public static let applePrefix = "com.apple."
    public static let maxOwnerLength = 160
    /// A wake further away than this is refused: nothing the scheduler plans is that far off.
    public static let maxDaysAhead: TimeInterval = 400

    private let booker: PmsetWakeBooker
    private let clock: () -> Date

    public init(runner: any CommandRunning = ShellCommandRunner(), timeZone: TimeZone = .current, clock: @escaping () -> Date = Date.init) {
        booker = PmsetWakeBooker(runner: runner, useSudo: false, timeZone: timeZone)
        self.clock = clock
    }

    // MARK: WakeHelperProtocol

    public func bookWake(at date: Date, owner: String, reply: @escaping (String?) -> Void) {
        if let problem = validate(owner: owner) ?? validateFuture(date) {
            reply(problem)
            return
        }
        reply(attempt { try booker.book(at: date, owner: owner) })
    }

    public func cancelEvent(kind: String, at date: Date, owner: String, reply: @escaping (String?) -> Void) {
        guard Self.wakeKinds.contains(kind) else {
            reply("Only wake events can be cancelled.")
            return
        }
        if let problem = validate(owner: owner) {
            reply(problem)
            return
        }
        reply(attempt { try booker.cancelEvent(kind: kind, at: date, owner: owner) })
    }

    public func version(reply: @escaping (String) -> Void) {
        reply(WakeHelperConstants.version)
    }

    // MARK: Checks

    private func validate(owner: String) -> String? {
        if owner.isEmpty || owner.count > Self.maxOwnerLength { return "The owner tag is empty or too long." }
        if owner.hasPrefix(Self.applePrefix) { return "Events owned by macOS are never touched." }
        // The owner is passed to pmset as an argument. Keep it printable so it can't be taken for anything else.
        if owner.hasPrefix("-") || owner.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "The owner tag has characters that aren't allowed."
        }
        return nil
    }

    private func validateFuture(_ date: Date) -> String? {
        let now = clock()
        if date <= now { return "That time has already passed." }
        if date.timeIntervalSince(now) > Self.maxDaysAhead * 86_400 { return "That is too far ahead to book." }
        return nil
    }

    private func attempt(_ work: () throws -> Void) -> String? {
        do {
            try work()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The helper's listener: hands each accepted connection to a `WakeHelperService`.
public final class WakeHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: WakeHelperService
    /// A signing requirement every peer must meet. `nil` accepts anyone, which is only for tests.
    private let requirement: String?

    public init(service: WakeHelperService, requirement: String?) {
        self.service = service
        self.requirement = requirement
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: (any WakeHelperProtocol).self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

/// The agent's side: a `WakeBooking` that asks the root helper.
public final class XPCWakeBooker: WakeBooking, PowerEventCancelling, @unchecked Sendable {
    public struct HelperError: Error, LocalizedError, Equatable {
        public var errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    private let makeConnection: () -> NSXPCConnection
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    /// - Parameter makeConnection: Builds a fresh connection. The real one targets the helper's Mach service.
    public init(timeout: TimeInterval = 15, makeConnection: @escaping () -> NSXPCConnection) {
        self.makeConnection = makeConnection
        self.timeout = timeout
    }

    /// The connection to the installed helper. `helperRequirement` makes sure it really is our helper.
    public convenience init(helperRequirement: String?, timeout: TimeInterval = 15) {
        self.init(timeout: timeout) {
            let connection = NSXPCConnection(machServiceName: WakeHelperConstants.machServiceName, options: .privileged)
            if let helperRequirement { connection.setCodeSigningRequirement(helperRequirement) }
            return connection
        }
    }

    public func book(at date: Date, owner: String) throws {
        try call { proxy, done in proxy.bookWake(at: date, owner: owner, reply: done) }
    }

    public func cancel(at date: Date, owner: String) throws {
        try cancelEvent(kind: "wake", at: date, owner: owner)
    }

    public func cancelEvent(kind: String, at date: Date, owner: String) throws {
        try call { proxy, done in proxy.cancelEvent(kind: kind, at: date, owner: owner, reply: done) }
    }

    /// The helper's version, or an error if it can't be reached.
    public func helperVersion() throws -> String {
        let box = ResultBox<String>()
        let proxy = try remoteProxy { box.finish(.failure(HelperError($0.localizedDescription))) }
        proxy.version { box.finish(.success($0)) }
        return try box.wait(timeout: timeout)
    }

    // MARK: Plumbing

    private func call(_ work: (any WakeHelperProtocol, @escaping (String?) -> Void) -> Void) throws {
        let box = ResultBox<String?>()
        let proxy = try remoteProxy { box.finish(.failure(HelperError($0.localizedDescription))) }
        work(proxy) { box.finish(.success($0)) }
        if let message = try box.wait(timeout: timeout) {
            throw HelperError(message)
        }
    }

    private func remoteProxy(onError: @escaping (Error) -> Void) throws -> any WakeHelperProtocol {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let fresh = makeConnection()
            fresh.remoteObjectInterface = NSXPCInterface(with: (any WakeHelperProtocol).self)
            fresh.invalidationHandler = { [weak self] in self?.dropConnection() }
            fresh.interruptionHandler = { [weak self] in self?.dropConnection() }
            fresh.resume()
            connection = fresh
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ onError($0) }) as? any WakeHelperProtocol else {
            throw HelperError("Couldn't reach the wake helper.")
        }
        return proxy
    }

    private func dropConnection() {
        lock.lock()
        connection = nil
        lock.unlock()
    }
}

/// Waits for one answer from a callback, with a time limit.
private final class ResultBox<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func finish(_ outcome: Result<Value, Error>) {
        lock.lock()
        let first = result == nil
        if first { result = outcome }
        lock.unlock()
        if first { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) throws -> Value {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw XPCWakeBooker.HelperError("The wake helper didn't answer. Is it switched on in Login Items?")
        }
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}
