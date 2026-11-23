// SPDX-License-Identifier: MIT OR Apache-2.0
/// What the zone editor holds while it is open: every layout it can switch
/// to, and a draft for each one opened, kept until it is saved or the editor
/// closes. Switching layouts never loses changes. Pure; the editor window
/// shows it.
public struct ZoneEditorSession: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var layout: ZoneLayout
        /// A `[layouts."<name>"]` of the user's: saved under its own name.
        /// Built-in layouts are only saved as a copy.
        public var isMine: Bool

        public init(layout: ZoneLayout, isMine: Bool) {
            self.layout = layout
            self.isMine = isMine
        }
    }

    public enum Target: Hashable, Sendable {
        case layout(String)
        /// A layout not saved yet, from a single zone.
        case new
    }

    public enum SaveProblem: Error, Equatable, Sendable {
        /// Not letters, digits, spaces, - or _.
        case invalidName
        case builtInName
        /// Another layout has this name: a copy never replaces it.
        case nameTaken
        /// A built-in or new layout needs a name.
        case needsName
    }

    /// In the order the picker shows them.
    public private(set) var entries: [Entry]
    public private(set) var current: Target
    /// The layout the editor opened on, followed through its saves (a copy of
    /// it, a new layout saved): the one the edited screen may take.
    public private(set) var origin: Target
    private var drafts: [Target: ZoneDraft] = [:]

    public static let blank = try! ZoneLayout(name: "new", zones: [.init(0, 0, 100, 100)])

    /// Opens on `start` (nil, or a name no entry has: a new layout).
    public init(entries: [Entry], start: String?) {
        self.entries = entries
        current = start.flatMap { name in entries.contains { $0.layout.name == name } ? .layout(name) : nil } ?? .new
        origin = current
    }

    /// The current layout is the one the editor opened on, or comes from it.
    public var isOrigin: Bool { current == origin }

    public func entry(_ target: Target) -> Entry? {
        guard case .layout(let name) = target else { return nil }
        return entries.first { $0.layout.name == name }
    }

    /// The layout as saved, the one a draft starts from.
    public func original(_ target: Target) -> ZoneLayout {
        entry(target)?.layout ?? Self.blank
    }

    /// The current layout being edited.
    public var draft: ZoneDraft {
        get { drafts[current] ?? ZoneDraft(original(current)) }
        set { drafts[current] = newValue }
    }

    /// The current layout is the user's: Save replaces it.
    public var isMine: Bool { entry(current)?.isMine == true }

    public func isModified(_ target: Target) -> Bool {
        drafts[target].map { $0.zones != original(target).zones } ?? false
    }

    /// The layouts with unsaved changes, in the picker's order, the new one last.
    public var modified: [Target] {
        (entries.map { Target.layout($0.layout.name) } + [.new]).filter(isModified)
    }

    /// Switches to another layout; the current one's changes stay.
    public mutating func open(_ target: Target) {
        if case .layout = target, entry(target) == nil { return }
        current = target
    }

    /// The layout Save writes: the current one under its name (`copyName`
    /// nil), or a copy under `copyName`.
    public func layoutToSave(copyName: String?) -> Result<ZoneLayout, SaveProblem> {
        let name: String
        if let copyName {
            guard ZoneLayout.isValidName(copyName) else { return .failure(.invalidName) }
            guard !ZoneLayout.builtIn.contains(where: { $0.name == copyName }) else { return .failure(.builtInName) }
            guard !entries.contains(where: { $0.layout.name == copyName }) else { return .failure(.nameTaken) }
            name = copyName
        } else {
            guard isMine, case .layout(let mine) = current else { return .failure(.needsName) }
            name = mine
        }
        // Every operation of a draft keeps it valid.
        return .success(try! draft.layout(named: name))
    }

    /// `layout` was written: it becomes the user's and the one edited, with no
    /// changes left. A copy leaves its source as it was saved.
    public mutating func saved(_ layout: ZoneLayout) {
        drafts[current] = nil
        if isOrigin { origin = .layout(layout.name) }
        if let i = entries.firstIndex(where: { $0.layout.name == layout.name }) {
            entries[i] = Entry(layout: layout, isMine: true)
        } else {
            entries.append(Entry(layout: layout, isMine: true))
        }
        current = .layout(layout.name)
        drafts[current] = nil
    }
}
