// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation

public struct SocketError: Error, CustomStringConvertible {
    public let operation: String
    public let code: Int32
    public var description: String { "\(operation): \(String(cString: strerror(code)))" }

    static func last(_ operation: String) -> SocketError { SocketError(operation: operation, code: errno) }
}

/// Minimal blocking Unix-domain stream socket helpers.
public enum UnixSocket {
    /// Connects to a listening socket. Returns the file descriptor.
    public static func connect(path: String, timeout: TimeInterval = 5) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        noSigPipe(fd)
        setTimeout(fd, timeout)
        let result = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let error = SocketError.last("connect \(path)")
            close(fd)
            throw error
        }
        return fd
    }

    /// Creates a listening socket at `path` (replacing a stale one), readable
    /// and writable by the current user only.
    public static func listen(path: String) throws -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        if directory == StateFiles.directory.path {
            try StateFiles.prepareDirectory()  // also brings an existing one back to 0700
        } else {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.last("socket") }
        let bound = try withAddress(path) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let error = SocketError.last("bind \(path)")
            close(fd)
            throw error
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let error = SocketError.last("listen")
            close(fd)
            throw error
        }
        return fd
    }

    /// Reads until a newline or EOF (newline excluded), at most `limit` bytes.
    public static func readLine(_ fd: Int32, limit: Int = 64 * 1024, deadline: TimeInterval = 5) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        // The socket timeout restarts at every byte: a client trickling bytes
        // would hold its connection open forever without an overall deadline.
        let end = Date().addingTimeInterval(deadline)
        while data.count < limit, Date() < end {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { return data }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    }

    /// Reads until EOF.
    public static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    public static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// Whether the peer process runs as the same user as us.
    public static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Writing to a socket whose peer already closed raises SIGPIPE, which kills
    /// the process silently by default. Make such writes fail with EPIPE instead.
    public static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, size)
    }

    private static func withAddress<T>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw SocketError(operation: "socket path too long (\(bytes.count) ≥ \(capacity))", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}
