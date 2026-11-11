import Darwin
import Foundation
import WakeUpCore

/// Listens on a Unix socket, reads one `ClientMessage` per connection, hands it to a handler along with
/// the connecting process's id, and writes back the `ServerMessage` it returns.
public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ClientMessage, Int32?) -> ServerMessage

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private let connections = DispatchQueue(label: "wakeup.server.connections", attributes: .concurrent)

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = try UnixSocket.listen(path: path)
        lock.lock()
        listenFD = fd
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.name = "wakeup.server.accept"
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        guard fd >= 0 else { return }
        // Shutting the socket down first is what wakes a thread blocked in accept().
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // the listening socket was closed
            }
            connections.async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        UnixSocket.setTimeout(fd: fd, seconds: 10)

        let reply: ServerMessage
        do {
            let line = try UnixSocket.readLine(fd: fd, maxBytes: 8_000_000)
            let message = try WakeUpJSON.makeDecoder().decode(ClientMessage.self, from: line)
            reply = handler(message, UnixSocket.peerProcessID(fd: fd))
        } catch let error as DecodingError {
            reply = .failure("That message was not understood: \(error.localizedDescription)")
        } catch {
            reply = .failure(error.localizedDescription)
        }

        guard var data = try? WakeUpJSON.makeCompactEncoder().encode(reply) else { return }
        data.append(10)
        try? UnixSocket.writeAll(fd: fd, data: data)
    }
}
