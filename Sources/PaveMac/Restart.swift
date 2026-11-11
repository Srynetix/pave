// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveIPC

/// A planned restart (`just dev`, `just deploy`, an update, a language
/// change): the quitting Pavé keeps the Dock hidden and its windows parked,
/// the next one carries on (DockController, WorkspaceController).
public enum RestartMarker {
    public static var url: URL { StateFiles.url("restarting") }
    public static var isSet: Bool { FileManager.default.fileExists(atPath: url.path) }
    public static func set() { try? StateFiles.touch(url) }
    public static func clear() { try? FileManager.default.removeItem(at: url) }
}

public enum Relaunch {
    /// Opens `app` once this Pavé has exited (one Pavé at a time), then quits
    /// as for a restart. Throws (and quits nothing) if the helper cannot start.
    @MainActor
    public static func afterExit(_ app: URL = URL(fileURLWithPath: Bundle.main.bundlePath), reason: String) throws {
        RestartMarker.set()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path goes as $0: never interpolated into the script.
        task.arguments = [
            "-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path,
        ]
        do {
            try task.run()
        } catch {
            RestartMarker.clear()
            throw error
        }
        Log.info("restarting (\(reason))")
        NSApp.terminate(nil)
    }
}
