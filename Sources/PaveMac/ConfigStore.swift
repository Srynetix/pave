import Foundation
import PaveCore

/// Reads `~/.config/pave/config.toml` (or `$PAVE_CONFIG`), writes the commented
/// template when the file does not exist, and reloads it whenever it changes.
///
/// An invalid file never replaces a valid configuration: the previous one stays
/// active and the problem is shown in the menu (`status`).
@MainActor
public final class ConfigStore {
    public enum Status: Equatable, Sendable {
        case defaults  // no file: built-in defaults
        case loaded(warnings: [PaveConfig.Problem])
        case invalid(PaveConfig.Problem)  // previous config kept
    }

    public let url: URL
    public private(set) var config = PaveConfig.default
    public private(set) var status = Status.defaults
    /// Called after every reload that changed the active configuration.
    public var onChange: ((PaveConfig) -> Void)?
    /// Called after every reload, even when the file was rejected (menu refresh).
    public var onStatusChange: (() -> Void)?

    private var lastText: String?
    private var watcher: DispatchSourceFileSystemObject?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["PAVE_CONFIG"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pave/config.toml")
    }

    /// Loads the file (creating it from the template if needed) and starts watching it.
    public func start() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try PaveConfig.template.write(to: url, atomically: true, encoding: .utf8)
                Log.info("config: created \(url.path) with the default settings")
            } catch {
                Log.info("config: cannot create \(url.path): \(error.localizedDescription)")
            }
        }
        reload()
        watch(directory)
    }

    /// Changes one setting in the file (menu, settings window), keeping the
    /// rest of the text as the user wrote it. Refused if the file is currently
    /// invalid (the user is editing it) or if the result would not parse.
    /// `logValue: false` for values that may name a customer (workspace names).
    /// Returns nil on success, else the reason.
    @discardableResult
    public func set(_ table: String, _ key: String, to value: String, logValue: Bool = true) -> String? {
        edit("\(table).\(key) set to \(logValue ? value : "(\(value.count) characters, not logged)")") {
            ConfigEdit.set(table, key, to: value, in: $0)
        }
    }

    /// Removes a setting: its default applies again.
    @discardableResult
    public func remove(_ table: String, _ key: String) -> String? {
        edit("\(table).\(key) removed") { ConfigEdit.remove(table, key, in: $0) }
    }

    /// Removes a whole table (an app rule).
    @discardableResult
    public func removeTable(_ table: String) -> String? {
        edit("[\(table)] removed") { ConfigEdit.removeTable(table, in: $0) }
    }

    /// Writes `[table]` anew with one setting, in one edit (a zone layout:
    /// `[zones.screens]` may name it, so it is never missing in between).
    @discardableResult
    public func replaceTable(_ table: String, _ key: String, to value: String) -> String? {
        edit("[\(table)] written") { ConfigEdit.set(table, key, to: value, in: ConfigEdit.removeTable(table, in: $0)) }
    }

    private func edit(_ what: String, _ transform: (String) -> String) -> String? {
        if case .invalid(let problem) = status { return "the file is invalid (\(problem)): fix it first" }
        let current = FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let edited = transform(current)
        guard edited != current else { return nil }
        do {
            _ = try PaveConfig.parse(edited)
        } catch {
            return "edit refused: \(error)"
        }
        do {
            // In place, not atomically: keeps the file's identity for editors
            // that have it open, and the watcher sees a plain write.
            try Data(edited.utf8).write(to: url)
        } catch {
            return "cannot write \(url.path): \(error.localizedDescription)"
        }
        Log.info("config: \(what) from Pavé")
        reload()
        return nil
    }

    /// Re-reads the file. Public for `pave config --reload` and tests.
    public func reload() {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            lastText = nil
            apply(.default, status: .defaults)
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        guard text != lastText else { return }  // editors touch the directory more than once
        lastText = text
        do {
            let (parsed, warnings) = try PaveConfig.parse(text)
            warnings.forEach { Log.info("config warning: \($0)") }
            apply(parsed, status: .loaded(warnings: warnings))
        } catch {
            Log.info("config REJECTED, previous settings kept: \(error)")
            status = .invalid(error)
            onStatusChange?()
        }
    }

    private func apply(_ new: PaveConfig, status: Status) {
        let changed = new != config
        config = new
        self.status = status
        if changed {
            Log.info(
                "config applied: workspaces \(new.workspacesEnabled ? "on" : "off"), "
                    + "switcher scope \(new.switcherScope.rawValue), \(new.activeBindings.count) hotkeys, "
                    + "\(new.appRules.count) app rule(s)")
            onChange?(new)
        }
        onStatusChange?()
    }

    /// Two watches, because editors save in two ways:
    /// - atomically (write a temp file, rename it over the old one): only the
    ///   *directory* sees it, and the old file descriptor now points to a dead file;
    /// - in place (VS Code, `echo >>`): only the *file* sees it.
    /// Every directory event re-arms the file watch on the new file. Bursts of
    /// events from one save are debounced.
    private func watch(_ directory: URL) {
        directoryWatcher = makeWatcher(directory.path, [.write, .rename, .delete]) { [weak self] in
            self?.watchFile()
            self?.scheduleReload()
        }
        if directoryWatcher == nil { Log.info("config: cannot watch \(directory.path), changes need a restart") }
        watchFile()
    }

    private func watchFile() {
        watcher?.cancel()
        watcher = makeWatcher(url.path, [.write, .extend, .delete, .rename, .attrib]) { [weak self] in
            self?.scheduleReload()
        }
    }

    private func makeWatcher(
        _ path: String, _ mask: DispatchSource.FileSystemEvent, _ handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
