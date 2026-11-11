import Foundation
import PaveIPC

/// Serves `pave` CLI requests on a Unix socket. Socket I/O runs on a private
/// queue; requests are handled on the main actor (where the registry lives).
public final class IPCServer: @unchecked Sendable {
    /// Called on the main actor; must call `reply` exactly once (possibly later).
    public typealias Handler =
        @MainActor @Sendable (IPCRequest, _ reply: @escaping @Sendable (IPCResponse) -> Void) -> Void

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "pave.ipc")
    /// Each client is read and answered on its own: a slow one holds no other.
    private let clients = DispatchQueue(label: "pave.ipc.clients", attributes: .concurrent)
    // Only touched on `queue` after start().
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    /// Inode of the socket we created: on stop, never delete a socket that a
    /// newer Pavé instance created at the same path.
    private var socketInode: ino_t = 0

    public init(path: String = IPCPaths.socket, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let fd = try UnixSocket.listen(path: path)
        listener = fd
        var info = stat()
        if stat(path, &info) == 0 { socketInode = info.st_ino }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
        Log.info("IPC listening on \(path)")
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
        }
        var info = stat()
        if stat(path, &info) == 0, info.st_ino == socketInode { unlink(path) }
    }

    // MARK: - On `queue`

    private func acceptPending() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        guard UnixSocket.peerIsCurrentUser(client) else {
            Log.info("IPC: rejected a connection from another user")
            close(client)
            return
        }
        UnixSocket.noSigPipe(client)
        // Generous send timeout: a layout command waits for the app's AX thread.
        UnixSocket.setTimeout(client, 5)
        let handler = self.handler
        clients.async { [self] in
            // A connection closed without a request (e.g. `pave` probing whether
            // Pavé is up): nobody to answer.
            guard let line = UnixSocket.readLine(client) else {
                close(client)
                return
            }
            guard let request = try? JSONDecoder().decode(IPCRequest.self, from: line) else {
                reply(.failure("invalid request"), to: client)
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    handler(request) { response in
                        self.clients.async { self.reply(response, to: client) }
                    }
                }
            }
        }
    }

    private func reply(_ response: IPCResponse, to client: Int32) {
        if let data = try? IPCCoding.encoder().encode(response) {
            UnixSocket.writeAll(client, data)
        }
        close(client)
    }
}
