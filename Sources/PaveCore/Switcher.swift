// SPDX-License-Identifier: MIT OR Apache-2.0
/// The window switcher, as a pure state machine.
///
/// A session lives from ⌃Tab to the release of ⌃ (or Return / Escape in search
/// mode). PaveMac feeds it the windows and the keys, shows `entries` and
/// `selection`, and performs the `Effect`s it returns. Nothing here touches
/// macOS, so every rule is unit-tested.
public struct SwitcherSession: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: WindowID
        public var pid: PID
        public var appName: String
        public var title: String
        public var state: WindowState
        /// Rank in the MRU order when the session opened (0 = current window).
        /// Logged on commit, without any title.
        public var mruRank: Int
    }

    public struct Options: Equatable, Sendable {
        public var scope: PaveConfig.SwitcherScope
        /// nil when workspaces are off: every window is listed.
        public var activeWorkspace: Int?
        /// Workspace of each window (windows absent from it are in the active one).
        public var workspaceOf: [WindowID: Int]
        /// Workspaces shown on the screens (one per screen). Empty: the active one only.
        public var visibleWorkspaces: Set<Int>
        /// ⌃`: only the windows of this app.
        public var onlyApp: PID?
        /// Scope `screen`: the windows shown on the screen in use.
        public var onScreen: Set<WindowID>

        public init(
            scope: PaveConfig.SwitcherScope = .workspace, activeWorkspace: Int? = nil,
            workspaceOf: [WindowID: Int] = [:], visibleWorkspaces: Set<Int> = [], onlyApp: PID? = nil,
            onScreen: Set<WindowID> = []
        ) {
            self.onScreen = onScreen
            self.scope = scope
            self.activeWorkspace = activeWorkspace
            self.workspaceOf = workspaceOf
            self.visibleWorkspaces = visibleWorkspaces
            self.onlyApp = onlyApp
        }
    }

    public enum Mode: Equatable, Sendable {
        /// ⌃ is held: keys are commands, releasing ⌃ commits.
        case held
        /// After Space: the panel stays open without ⌃, keys type the query,
        /// Return commits and Escape cancels.
        case search
    }

    /// What PaveMac must do.
    public enum Effect: Equatable, Sendable {
        case focus(WindowID, mruRank: Int)
        case close(WindowID)
        case quit(PID)
        case dismiss
    }

    /// All the windows of the session, in MRU order (minus closed ones).
    public private(set) var all: [Entry]
    /// What is shown: `all` filtered by the query, best match first.
    public private(set) var entries: [Entry]
    /// Index in `entries`; nil when nothing matches.
    public private(set) var selection: Int?
    public private(set) var query = ""
    public private(set) var mode = Mode.held
    public let options: Options

    /// `windows` in MRU order (`WindowStore.orderedWindows`). ⌃Tab selects the
    /// previous window (index 1), ⌃⇧Tab (`backwards`) the least recent one, so
    /// a quick ⌃Tab+release flips between the two most recent windows.
    public init(windows: [WindowSnapshot], options: Options = Options(), backwards: Bool = false) {
        self.options = options
        all = windows.enumerated().compactMap { rank, window in
            guard Self.isListed(window, options) else { return nil }
            return Entry(
                id: window.id, pid: window.pid, appName: window.appName, title: window.title,
                state: window.state, mruRank: rank)
        }
        entries = all
        switch entries.count {
        case 0: selection = nil
        case 1: selection = 0
        default: selection = backwards ? entries.count - 1 : 1
        }
    }

    static func isListed(_ window: WindowSnapshot, _ options: Options) -> Bool {
        if let app = options.onlyApp, window.pid != app { return false }
        if options.scope == .screen { return options.onScreen.contains(window.id) }
        if options.scope == .workspace, let active = options.activeWorkspace {
            let workspace = options.workspaceOf[window.id] ?? active
            return options.visibleWorkspaces.isEmpty
                ? workspace == active : options.visibleWorkspaces.contains(workspace)
        }
        return true
    }

    public var selected: Entry? { selection.map { entries[$0] } }

    // MARK: - Navigation

    /// Tab / → : next entry, wrapping around.
    public mutating func next() { step(1) }
    /// ⇧Tab / ← : previous entry, wrapping around.
    public mutating func previous() { step(-1) }

    /// ↑ / ↓ in a grid of `columns` cards per row: same column, row above or
    /// below; stops at the edges instead of wrapping (as a grid should).
    public mutating func vertical(_ delta: Int, columns: Int) {
        guard let selection, columns > 0 else { return }
        let target = selection + delta * columns
        if entries.indices.contains(target) { self.selection = target }
    }

    private mutating func step(_ delta: Int) {
        guard let selection, !entries.isEmpty else { return }
        self.selection = (selection + delta + entries.count) % entries.count
    }

    public mutating func select(_ id: WindowID) {
        if let index = entries.firstIndex(where: { $0.id == id }) { selection = index }
    }

    // MARK: - Search

    /// Space: from now on, keys type the query and releasing ⌃ does not commit.
    public mutating func enterSearch() { mode = .search }

    public mutating func type(_ text: String) {
        guard mode == .search else { return }
        setQuery(query + text)
    }

    public mutating func deleteBackward() {
        guard mode == .search, !query.isEmpty else { return }
        setQuery(String(query.dropLast()))
    }

    private mutating func setQuery(_ new: String) {
        query = new
        refilter(keeping: nil)
    }

    /// Filters `all` by the query and ranks the matches. With a query, the best
    /// match is selected; `keeping` keeps the selection on that window if it
    /// is still listed (after a close, a quit, or a registry update).
    private mutating func refilter(keeping id: WindowID?) {
        if query.isEmpty {
            entries = all
        } else {
            let needle = Search.fold(query)
            entries = all.compactMap { entry in Search.score(needle, entry).map { (entry, $0) } }
                .enumerated()
                .sorted { a, b in a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset }
                .map(\.element.0)
        }
        if let id, let index = entries.firstIndex(where: { $0.id == id }) {
            selection = index
        } else {
            selection = entries.isEmpty ? nil : 0
        }
    }

    // MARK: - Ending and actions

    /// ⌃ released (held mode) or Return (search mode).
    public func commit() -> Effect {
        guard let selected else { return .dismiss }
        return .focus(selected.id, mruRank: selected.mruRank)
    }

    /// W: closes the selected window. The entry goes away at once, and the
    /// selection moves to the next one, so W can be pressed again.
    public mutating func closeSelected() -> Effect? {
        guard let selection, let entry = selected else { return nil }
        let following = entries.indices.contains(selection + 1) ? entries[selection + 1].id : nil
        all.removeAll { $0.id == entry.id }
        refilter(keeping: following)
        if following == nil, let last = entries.indices.last { self.selection = last }
        return .close(entry.id)
    }

    /// Q: quits the app of the selected window; all its windows go away.
    public mutating func quitSelectedApp() -> Effect? {
        guard let selection, let entry = selected else { return nil }
        let following = entries[(selection + 1)...].first { $0.pid != entry.pid }?.id
        all.removeAll { $0.pid == entry.pid }
        refilter(keeping: following)
        if following == nil, let last = entries.indices.last { self.selection = last }
        return .quit(entry.pid)
    }

    /// The registry changed while the panel is open. Windows that went away are
    /// dropped, new ones are appended at the end, and titles and states are
    /// refreshed. The order is *not* re-sorted: cards jumping around under the
    /// user's eyes would make them pick the wrong one.
    public mutating func update(windows: [WindowSnapshot]) {
        let current = selected?.id
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        all = all.compactMap { entry in
            guard let window = byID[entry.id], Self.isListed(window, options) else { return nil }
            var updated = entry
            updated.title = window.title
            updated.state = window.state
            return updated
        }
        let known = Set(all.map(\.id))
        for (rank, window) in windows.enumerated() where !known.contains(window.id) && Self.isListed(window, options) {
            all.append(
                Entry(
                    id: window.id, pid: window.pid, appName: window.appName, title: window.title,
                    state: window.state, mruRank: rank))
        }
        refilter(keeping: current)
    }
}

/// Search in the switcher: case- and accent-insensitive, on "app title".
enum Search {
    /// Lowercased, accents removed (French and common Latin ones; PaveCore stays
    /// Foundation-free, so no `folding(options:)`).
    static func fold(_ text: String) -> [Character] {
        let table: [Character: Character] = [
            "à": "a", "â": "a", "ä": "a", "á": "a", "ã": "a", "å": "a",
            "é": "e", "è": "e", "ê": "e", "ë": "e",
            "î": "i", "ï": "i", "í": "i", "ì": "i",
            "ô": "o", "ö": "o", "ó": "o", "ò": "o", "õ": "o",
            "ù": "u", "û": "u", "ü": "u", "ú": "u",
            "ç": "c", "ñ": "n", "ÿ": "y",
        ]
        return text.lowercased().map { table[$0] ?? $0 }
    }

    /// nil = no match. Higher is better:
    /// 3: the app name starts with the query ("sl" → Slack);
    /// 2: a word of the app name or title starts with it;
    /// 1: the query letters appear in order ("brw" → Brave Browser).
    static func score(_ needle: [Character], _ entry: SwitcherSession.Entry) -> Int? {
        score(needle, name: entry.appName, extra: entry.title)
    }

    /// Same scoring on any name (the launcher's app names).
    static func score(_ needle: [Character], name: String, extra: String = "") -> Int? {
        guard !needle.isEmpty else { return 0 }
        let app = fold(name)
        if app.starts(with: needle) { return 3 }
        let haystack = app + [" "] + fold(extra)
        for start in haystack.indices where start == 0 || !haystack[start - 1].isLetter && !haystack[start - 1].isNumber
        {
            if haystack[start...].starts(with: needle) { return 2 }
        }
        var rest = needle[...]
        for c in haystack where c == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return 1 }
        }
        return nil
    }
}
