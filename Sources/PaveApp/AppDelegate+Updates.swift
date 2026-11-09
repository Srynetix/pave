import AppKit
import PaveCore
import PaveIPC
import PaveMac
import ServiceManagement

/// Pavé's own updates: schedule, menu item, confirmation, `pave update`.
extension AppDelegate {
    // MARK: - Updates

    /// Checks at launch and once a day, from the installed copy only.
    func applyUpdates(_ c: PaveConfig) {
        let wanted = c.updatesCheck && UpdateService.isInstalledCopy
        guard c.updatesSource != updates.source || wanted != updatesScheduled else { return }
        updates.source = c.updatesSource
        updatesScheduled = wanted
        updates.schedule(wanted)
    }

    /// The menu item: install the newer Pavé found, or look for one.
    @objc func updateFromMenu() {
        if case .available(let release) = updates.status { return confirmUpdate(release) }
        updates.check { [weak self] status in
            guard let self else { return }
            switch status {
            case .available(let release): self.confirmUpdate(release)
            case .upToDate: self.showAlert(String(localized: "Pavé is up to date"), String(localized: "Version \(self.updates.current) is the latest."))
            case .failed(let message): self.showAlert(String(localized: "Could not look for updates"), message)
            default: break
            }
        }
    }

    /// What the newer releases bring, then install and restart.
    func confirmUpdate(_ release: Updates.Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Install Pavé \(release.version)?")
        var notes = updates.newer.map { "\($0.version)\n\($0.notes.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n\n")
        if notes.count > 1500 { notes = String(notes.prefix(1500)) + "…" }
        alert.informativeText = String(localized: "You have version \(updates.current). Pavé restarts once it is installed.") + "\n\n" + notes
        alert.addButton(withTitle: String(localized: "Install and Restart"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updates.install(release) { [weak self] error in
            if let error { self?.showAlert(String(localized: "Could not install the update"), error) }
        }
    }

    /// One line for Settings and `pave update`.
    var updateStatusText: String {
        switch updates.status {
        case .idle: return UpdateService.isInstalledCopy ? String(localized: "Not checked yet") : String(localized: "Development build: updates go to the copy in Applications")
        case .checking: return String(localized: "Checking…")
        case .upToDate(let date): return String(localized: "Up to date (checked \(date.formatted(date: .omitted, time: .shortened)))")
        case .available(let release): return String(localized: "Pavé \(release.version) is available")
        case .installing(let version): return String(localized: "Installing Pavé \(version)…")
        case .failed(let message): return String(localized: "Failed: \(message)")
        }
    }

    func updateCommand(_ args: [String], reply: @escaping @Sendable (IPCResponse) -> Void) {
        switch UpdateCommand.parse(args) {
        case .failure(let usage): reply(.failure(usage.description))
        case .success(.check):
            updates.check { [weak self] status in
                guard let self else { return }
                if case .failed = status { return reply(.failure(self.updateStatusText)) }
                var text = "Pavé \(self.updates.current) · \(self.updates.source)\n\(self.updateStatusText)"
                for release in self.updates.newer {
                    text += "\n\n\(release.version)\n\(release.notes.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                if case .available = status { text += "\n\npave update install: install it and restart Pavé" }
                reply(IPCResponse(ok: true, message: text))
            }
        case .success(.install):
            updates.check { [weak self] status in
                guard let self else { return }
                guard case .available(let release) = status else { return reply(.failure(self.updateStatusText)) }
                self.updates.install(release) { error in
                    reply(error.map { IPCResponse.failure($0) } ?? IPCResponse(ok: true, message: "Pavé \(release.version) installed, Pavé restarts"))
                }
            }
        }
    }
}
