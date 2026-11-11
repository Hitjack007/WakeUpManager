import Darwin
import Foundation

public enum SocketError: Error, LocalizedError, Equatable {
    case pathTooLong(String)
    case system(String, Int32)
    case messageTooLarge
    case closed

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            "The socket path is too long: \(path)"
        case .system(let what, let code):
            "\(what) failed: \(String(cString: strerror(code)))"
        case .messageTooLarge:
            "The message is too large."
        case .closed:
            "The connection closed before a message arrived."
        }
    }
}

/// Small helpers over POSIX Unix-domain sockets, shared by the client and the agent's server.
package enum UnixSocket {
    package static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)   // includes the terminating NUL
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        return address
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    package static func setTimeout(fd: Int32, seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Connects to a listening socket. The timeout applies to later reads and writes.
    package static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        var address = try address(for: path)
        let fd = try makeSocket()
        setTimeout(fd: fd, seconds: timeout)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system("connect to \(path)", code)
        }
        return fd
    }

    /// Creates a listening socket at `path`, replacing a stale one, readable and writable only by this user.
    package static func listen(path: String, backlog: Int32 = 16) throws -> Int32 {
        var address = try address(for: path)
        let fd = try makeSocket()
        unlink(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system("bind \(path)", code)
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, backlog) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system("listen", code)
        }
        return fd
    }

    /// Reads up to the first newline (or the end of the stream).
    package static func readLine(fd: Int32, maxBytes: Int) throws -> Data {
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("read", errno)
            }
            if count == 0 {
                if collected.isEmpty { throw SocketError.closed }
                return collected
            }
            if let newline = chunk[..<count].firstIndex(of: 10) {
                collected.append(contentsOf: chunk[..<newline])
                return collected
            }
            collected.append(contentsOf: chunk[..<count])
            if collected.count > maxBytes { throw SocketError.messageTooLarge }
        }
    }

    package static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.system("write", errno)
                }
                offset += written
            }
        }
    }

    /// The process id of the other end of a connected Unix socket.
    package static func peerProcessID(fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }
}

/// Anything that can deliver a message to the scheduler and bring back its answer.
public protocol SchedulerClient {
    func send(_ message: ClientMessage) throws -> ServerMessage
}

/// Talks to the scheduler agent over its Unix socket.
public struct SocketClient: SchedulerClient {
    public var path: String
    public var timeout: TimeInterval

    public init(path: String = WakeUpPaths.socketPath, timeout: TimeInterval = 10) {
        self.path = path
        self.timeout = timeout
    }

    public func send(_ message: ClientMessage) throws -> ServerMessage {
        let fd = try UnixSocket.connect(path: path, timeout: timeout)
        defer { close(fd) }
        var data = try WakeUpJSON.makeCompactEncoder().encode(message)
        data.append(10)
        try UnixSocket.writeAll(fd: fd, data: data)
        let line = try UnixSocket.readLine(fd: fd, maxBytes: 8_000_000)
        return try WakeUpJSON.makeDecoder().decode(ServerMessage.self, from: line)
    }
}
