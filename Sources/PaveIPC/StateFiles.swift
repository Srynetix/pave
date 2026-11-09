import Foundation

/// Pavé's state directory, `~/.local/state/pave`: the socket, the workspaces
/// and tiling state, the arrangements, the saved Dock settings, the restart
/// marker. Private to the user: the directory is 0700 (fixed if it already
/// exists with other permissions) and every file 0600.
public enum StateFiles {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/pave")
    }

    public static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Creates the directory, or brings an existing one back to 0700.
    public static func prepareDirectory() throws {
        let fm = FileManager.default
        let path = directory.path
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let mode = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber, mode.intValue & 0o777 != 0o700 {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
    }

    /// Writes `data` to `url` (in the state directory) atomically, as 0600:
    /// a temporary file created 0600, then renamed over the old one.
    public static func write(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// An empty file (a marker), 0600.
    public static func touch(_ url: URL) throws { try write(Data(), to: url) }
}
