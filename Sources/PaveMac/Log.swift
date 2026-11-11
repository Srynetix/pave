// SPDX-License-Identifier: MIT OR Apache-2.0
import Foundation
import Synchronization

/// Timestamped logger.
///
/// Every line goes to `~/Library/Logs/Pave/pave.log`, rotated at 5 MB into
/// `pave.1.log` and `pave.2.log` (≈ 15 MB at most), so a week of daily use can
/// be read back (Rapport M1). Lines also go to stderr (`build/pave.log` with
/// `just dev`). Titles stay redacted, as everywhere: the log never holds window
/// contents. Thread-safe: the event tap thread logs too.
public enum Log {
    /// Window titles are redacted unless PAVE_LOG_TITLES=1 (local debugging only).
    public static let showTitles = ProcessInfo.processInfo.environment["PAVE_LOG_TITLES"] == "1"

    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Pave", isDirectory: true)
    public static var fileURL: URL { directory.appendingPathComponent("pave.log") }
    static let maxBytes: UInt64 = 5_000_000
    static let keptFiles = 2

    private final class Sink: Sendable {
        let state = Mutex<(handle: FileHandle?, size: UInt64, opened: Bool)>((nil, 0, false))

        func write(_ line: String) {
            let data = Data(line.utf8)
            FileHandle.standardError.write(data)
            state.withLock { s in
                if !s.opened {
                    s.opened = true
                    s.handle = Self.open(&s.size)
                }
                guard let handle = s.handle else { return }
                if s.size + UInt64(data.count) > Log.maxBytes {
                    try? handle.close()
                    Self.rotate()
                    s.handle = Self.open(&s.size)
                }
                s.handle?.write(data)
                s.size += UInt64(data.count)
            }
        }

        private static func open(_ size: inout UInt64) -> FileHandle? {
            let fm = FileManager.default
            try? fm.createDirectory(at: Log.directory, withIntermediateDirectories: true)
            let path = Log.fileURL.path
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
            size = (try? handle.seekToEnd()) ?? 0
            return handle
        }

        /// pave.log → pave.1.log → pave.2.log (the oldest is dropped).
        private static func rotate() {
            let fm = FileManager.default
            func url(_ n: Int) -> URL {
                n == 0 ? Log.fileURL : Log.directory.appendingPathComponent("pave.\(n).log")
            }
            try? fm.removeItem(at: url(Log.keptFiles))
            for n in stride(from: Log.keptFiles - 1, through: 0, by: -1) {
                try? fm.moveItem(at: url(n), to: url(n + 1))
            }
        }
    }

    private static let sink = Sink()

    /// Local time with the date: a week of logs must stay readable.
    /// DateFormatter is thread-safe for formatting once configured.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    public static func info(_ message: @autoclosure () -> String) {
        sink.write("\(formatter.string(from: Date())) [pave] \(message())\n")
    }
}
