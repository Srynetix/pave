// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore

/// The Trash button: full or empty, checked off the main thread.
extension TaskbarController {
    /// Full or empty Trash icon (neutral if macOS does not let Pavé look).
    func updateTrash() {
        // Off the main thread: the Finder may take its time to answer.
        trashQueue.async {
            let empty = Trash.isEmpty
            DispatchQueue.main.async { MainActor.assumeIsolated { self.showTrash(empty) } }
        }
    }

    /// Asking the Finder costs an `osascript` process (≈ 130 ms, ~/.Trash is
    /// protected): every 5 s while the Finder is in front, where files get
    /// deleted, else every minute (polling every 5 s was the main
    /// source of idle wake-ups).
    func scheduleTrashCheck() {
        let interval: TimeInterval = finderWasFrontmost ? 5 : 60
        guard trashTimer?.timeInterval != interval else { return }
        trashTimer?.invalidate()
        trashTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTrash() }
        }
        trashTimer?.tolerance = interval / 10
    }

    func showTrash(_ empty: Bool?) {
        guard trashEmpty != .some(empty) else { return }
        if trashEmpty == nil, empty == nil { Log.info("trash: contents not readable, neutral icon") }
        trashEmpty = .some(empty)
        // The Dock's own Trash icons (empty bin / bin with papers); a plain
        // symbol while the state is unknown.
        for panel in panels.values {
            if let empty, let image = NSImage(named: empty ? NSImage.trashEmptyName : NSImage.trashFullName) {
                panel.trashButton.setImage(image)
            } else {
                panel.trashButton.setSymbol("trash", label: String(localized: "Trash"))
            }
        }
    }
}
