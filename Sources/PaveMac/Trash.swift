// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit

/// The Trash in the taskbar (the one thing the user missed from the Dock).
/// Opening it is a plain Finder window; emptying goes through the Finder
/// (Apple Events: macOS asks once for the permission), after Pavé's own
/// confirmation — there is no public API to empty the Trash, and deleting
/// files by hand would skip the other volumes' trashes.
@MainActor
enum Trash {
    nonisolated static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    /// nil when Pavé cannot tell (the icon then stays neutral). ~/.Trash is
    /// protected by macOS: Pavé asks the Finder instead, but only once the
    /// user has let it drive the Finder (first "Empty Trash"), never
    /// prompting from this background check.
    /// Blocking (Apple Event): call off the main thread.
    nonisolated static var isEmpty: Bool? {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            return items.allSatisfy { $0 == ".DS_Store" || $0 == ".localized" }
        }
        guard finderAutomationGranted, let count = countThroughFinder() else { return nil }
        return count == 0
    }

    /// Already allowed to send Apple Events to the Finder (without asking).
    nonisolated static var finderAutomationGranted: Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == noErr
    }

    static func open() {
        NSWorkspace.shared.open(url)
    }

    /// Runs a Finder AppleScript in `osascript`, off the main thread: the
    /// Finder answers `empty trash` only once every file is gone, and Pavé's
    /// bar, switcher and hotkeys must not wait for it (they used to
    /// freeze). Returns the output, or the AppleScript error number only:
    /// a message may name files in the Trash.
    nonisolated static func runFinderScript(_ script: String) -> (output: String?, error: Int?) {
        guard let result = try? Shell.run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to \(script)"])
        else { return (nil, -1) }
        let output = result.text
        let message = result.errorText
        guard result.status == 0 else {
            // "… execution error: … (-128)": keep the number.
            let code = message.range(of: #"\(-?\d+\)"#, options: [.regularExpression, .backwards])
                .flatMap { Int(message[$0].dropFirst().dropLast()) }
            return (nil, code ?? Int(result.status))
        }
        return (output.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }

    /// Items in the Trash, asked to the Finder (the user chose to empty it, so
    /// the Automation prompt may show here). nil if the Finder did not answer.
    nonisolated static func countThroughFinder() -> Int? {
        runFinderScript("count items of trash").output.flatMap { Int($0) }
    }

    private static let queue = DispatchQueue(label: "pave.trash")

    /// Asks, then empties through the Finder. `done(true)` once emptied.
    /// An empty Trash is reported as such (the Finder answers -128 otherwise).
    /// The Finder works in the background: Pavé stays responsive meanwhile.
    static func emptyAfterConfirmation(done: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let count = countThroughFinder()
            DispatchQueue.main.async { MainActor.assumeIsolated { confirm(count: count, done: done) } }
        }
    }

    private static func confirm(count: Int?, done: @escaping @MainActor (Bool) -> Void) {
        NSApp.activate()
        if count == 0 {
            let empty = NSAlert()
            empty.messageText = String(localized: "The Trash is already empty")
            empty.runModal()
            return done(false)
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Empty the Trash?")
        alert.informativeText = String(localized: "The items in the Trash will be deleted permanently.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Empty Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return done(false) }
        let start = Date()
        queue.async {
            let error = runFinderScript("empty trash").error
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finished(error: error, items: count, ms: ms, done: done) }
            }
        }
    }

    private static func finished(error code: Int?, items: Int?, ms: Int, done: @escaping @MainActor (Bool) -> Void) {
        guard let code else {
            Log.info("trash: emptied through the Finder, \(items.map(String.init) ?? "?") item(s), \(ms) ms")
            return done(true)
        }
        Log.info("trash: empty FAILED (\(code)) after \(ms) ms")
        let failure = NSAlert()
        failure.messageText = String(localized: "The Trash was not emptied")
        switch code {
        case -1743:  // errAEEventNotPermitted
            failure.informativeText = String(
                localized:
                    "Pavé is not allowed to control the Finder. Allow it in System Settings › Privacy & Security › Automation, then try again."
            )
        case -128:  // userCanceledErr
            failure.informativeText = String(
                localized:
                    "The Finder cancelled: a request (password, confirmation) was refused, or an item is locked or in use. Empty the Trash from the Finder to see which one."
            )
        case -1712:  // errAETimeout
            failure.informativeText = String(localized: "The Finder did not answer in time. Try again in a moment.")
        default:
            failure.informativeText = String(localized: "The Finder returned error \(code).")
        }
        NSApp.activate()
        failure.runModal()
        done(false)
    }
}
