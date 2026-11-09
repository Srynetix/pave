/// The workspace numbers of one taskbar: the workspaces that live on this
/// screen and have windows, plus the one shown there even when empty. Pure:
/// PaveMac draws them and switches on a click.
public enum WorkspaceIndicator {
    public struct Item: Equatable, Sendable {
        public var number: Int
        /// Shown on this screen right now.
        public var isVisible: Bool
        /// From `workspaces.names`; shown as a tooltip, never logged.
        public var name: String?
        /// From `workspaces.icons`: drawn instead of the number, never logged.
        public var icon: WorkspaceIcon? = nil
    }

    /// - `screenID`: the bar's screen; `primaryID`: where a workspace without
    ///   a home screen is counted.
    public static func items(
        for screenID: String, primaryID: String, state: Workspaces, windows: [WindowSnapshot], names: [String] = [],
        icons: [String] = []
    ) -> [Item] {
        // Same windows as the bar lists: standard ones, minimized included.
        let occupied = Set(
            windows.filter { $0.subrole == "AXStandardWindow" || $0.state == .minimized }.map { state.workspace(of: $0.id) })
        let shownHere = state.visible[screenID] ?? (screenID == primaryID ? state.active : nil)
        return Workspaces.range.compactMap { n in
            let home = state.screen(showing: n) ?? state.home[n] ?? primaryID
            guard home == screenID, occupied.contains(n) || n == shownHere else { return nil }
            let name = n <= names.count && !names[n - 1].isEmpty ? names[n - 1] : nil
            let icon = n <= icons.count ? WorkspaceIcon(icons[n - 1]) : nil
            return Item(number: n, isVisible: n == shownHere, name: name, icon: icon)
        }
    }
}

/// What a workspace shows in the taskbar instead of its number: a short text
/// (an emoji, a letter or two) or an SF Symbol (`"sf:globe"`).
public enum WorkspaceIcon: Equatable, Sendable {
    case text(String)
    case symbol(String)

    /// Longest text: an emoji (one character, however many scalars) or two letters.
    public static let maxCharacters = 2

    /// Nil for "" (the number stays) and for a value that is no icon.
    public init?(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("sf:") {
            let name = String(value.dropFirst(3))
            guard Self.isSymbolName(name) else { return nil }
            self = .symbol(name)
        } else {
            guard !value.isEmpty, value.count <= Self.maxCharacters, !value.contains(where: \.isNewline) else { return nil }
            self = .text(value)
        }
    }

    /// Whether `value` can be written in `workspaces.icons` ("" included).
    public static func isValid(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespaces).isEmpty || WorkspaceIcon(value) != nil
    }

    /// SF Symbol names: lowercase words, digits and dots ("chevron.left.forwardslash.chevron.right").
    static func isSymbolName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 80 && name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." }
            && name.first != "." && name.last != "."
    }
}
