import Foundation

// The things the engine needs from the outside world. Real implementations (the root helper, power
// assertions, process launching, the battery, notifications, disk) are added later; tests use fakes.

/// Books and cancels wake events. The real one talks to the root helper.
public protocol WakeBooking {
    func book(at date: Date, owner: String) throws
    func cancel(at date: Date, owner: String) throws
}

/// Holds the Mac awake. Calls must be idempotent: `hold` twice is the same as once.
public protocol AwakeHolder {
    func hold(reason: String)
    func release()
}

public enum ProcessStatus: Equatable, Sendable {
    case running
    /// Not running any more. The exit code is `nil` when it isn't known (for example an app that quit).
    case exited(Int32?)
}

/// Starts jobs and reports whether they are still running.
public protocol JobLauncher {
    /// Starts the job and returns a handle for later `status` and `terminate` calls. The launcher is
    /// responsible for telling the job its execution id and how to report back.
    func launch(_ launch: Launch, executionId: UUID) throws -> String
    func status(of handle: String) -> ProcessStatus
    func terminate(handle: String)
}

public protocol PowerSensor {
    func current() -> PowerState
}

public protocol UserNotifier {
    func notify(_ notice: Notice)
}

public protocol StateStore {
    func load() throws -> EngineState?
    func save(_ state: EngineState) throws
}

public struct EnginePorts {
    public var wakes: any WakeBooking
    public var awake: any AwakeHolder
    public var launcher: any JobLauncher
    public var power: any PowerSensor
    public var notifier: any UserNotifier
    public var store: any StateStore

    public init(
        wakes: any WakeBooking,
        awake: any AwakeHolder,
        launcher: any JobLauncher,
        power: any PowerSensor,
        notifier: any UserNotifier,
        store: any StateStore
    ) {
        self.wakes = wakes
        self.awake = awake
        self.launcher = launcher
        self.power = power
        self.notifier = notifier
        self.store = store
    }
}

// MARK: - State stores

/// Keeps the state in memory. Useful for tests and for running without persistence.
public final class InMemoryStateStore: StateStore {
    public private(set) var saved: EngineState?
    public private(set) var saveCount = 0

    public init(initial: EngineState? = nil) {
        saved = initial
    }

    public func load() throws -> EngineState? { saved }

    public func save(_ state: EngineState) throws {
        saved = state
        saveCount += 1
    }
}

/// Keeps the state in a JSON file, written atomically.
public struct JSONFileStateStore: StateStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> EngineState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try WakeUpJSON.makeDecoder().decode(EngineState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: EngineState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try WakeUpJSON.makeEncoder().encode(state).write(to: url, options: .atomic)
    }
}
