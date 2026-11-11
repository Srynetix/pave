// SPDX-License-Identifier: MIT OR Apache-2.0
/// Logical modifiers, as received *after* Karabiner / hidutil remapping.
public struct Modifiers: OptionSet, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let command = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)

    public var description: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A key (virtual key code, layout independent) plus the exact set of modifiers.
public struct Hotkey: Hashable, Sendable, CustomStringConvertible {
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(_ keyCode: UInt16, _ modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public enum Key {
        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
        public static let downArrow: UInt16 = 125
        public static let upArrow: UInt16 = 126
        public static let tab: UInt16 = 48
        public static let z: UInt16 = 6
        public static let a: UInt16 = 0
        /// Top-row digit keys 1…9 (virtual key codes, layout independent).
        public static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    }

    /// The keys pressed for this shortcut with the "pc" keyboard preset, which
    /// turns the key next to the space bar (⌘) into ⌃ and the bottom-left key
    /// into ⌘: shown to the user instead of what macOS receives.
    public var pressedWithPCPreset: Hotkey {
        var pressed = modifiers.subtracting([.control, .command])
        if modifiers.contains(.control) { pressed.insert(.command) }
        if modifiers.contains(.command) { pressed.insert(.control) }
        return Hotkey(keyCode, pressed)
    }

    public var description: String {
        modifiers.description + (Self.symbols[keyCode] ?? Self.names[keyCode]?.uppercased() ?? "key\(keyCode)")
    }

    // MARK: - Names (config file)

    /// Key names usable in `config.toml`. Virtual key codes are *positions*:
    /// letters are stored as the US QWERTY key, and the tap matches the key
    /// that types that letter in the active layout (`HotkeyService`), so `z`
    /// is the AZERTY Z key too. Punctuation stays a position; arrows,
    /// digits, tab… are the same everywhere.
    public static let keyCodes: [String: UInt16] = {
        var table: [String: UInt16] = [
            "left": Key.leftArrow, "right": Key.rightArrow, "down": Key.downArrow, "up": Key.upArrow,
            "tab": 48, "space": 49, "return": 36, "enter": 36, "escape": 53, "esc": 53,
            "delete": 51, "backspace": 51, "grave": 50, "`": 50, "section": 10,
            "minus": 27, "-": 27, "equal": 24, "=": 24, "comma": 43, ",": 43, "period": 47, ".": 47,
            "slash": 44, "/": 44, "semicolon": 41, ";": 41, "quote": 39, "'": 39,
            "leftbracket": 33, "[": 33, "rightbracket": 30, "]": 30, "backslash": 42, "\\": 42,
        ]
        for (n, code) in Key.digits.enumerated() { table["\(n + 1)"] = code }
        table["0"] = 29
        let letters: [(String, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8),
            ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
            ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (name, code) in letters { table[name] = code }
        let fkeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (n, code) in fkeys.enumerated() { table["f\(n + 1)"] = code }
        return table
    }()

    /// Canonical name of each key code (the longest alias, e.g. "escape" over "esc").
    static let names: [UInt16: String] = {
        var result: [UInt16: String] = [:]
        for (name, code) in keyCodes where name.count > (result[code]?.count ?? 0) { result[code] = name }
        return result
    }()

    static let symbols: [UInt16: String] = [
        Key.leftArrow: "←", Key.rightArrow: "→", Key.downArrow: "↓", Key.upArrow: "↑",
        48: "Tab", 49: "Space", 36: "↩", 53: "Esc", 50: "`",
    ]

    static let modifierNames: [String: Modifiers] = [
        "ctrl": .control, "control": .control, "⌃": .control,
        "alt": .option, "opt": .option, "option": .option, "⌥": .option,
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
    ]

    public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    /// `"ctrl+shift+left"` → hotkey; `"none"` or `""` → nil (unbound).
    /// Case-insensitive; at least one modifier is required, so a global hotkey
    /// never swallows a plain key.
    public static func parse(_ text: String) throws(ParseError) -> Hotkey? {
        let trimmed = text.trimmedSpaces.lowercased()
        if trimmed.isEmpty || trimmed == "none" { return nil }
        // "+" may itself be a key only as the last part: no such key in the table, so split simply.
        let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map { String($0).trimmedSpaces }
        guard let keyName = parts.last, !keyName.isEmpty else {
            throw ParseError(message: "'\(text)': missing key after '+'")
        }
        var modifiers: Modifiers = []
        for part in parts.dropLast() {
            guard let modifier = modifierNames[part] else {
                throw ParseError(message: "'\(text)': unknown modifier '\(part)' (ctrl, alt, cmd, shift)")
            }
            modifiers.insert(modifier)
        }
        guard let code = keyCodes[keyName] else {
            throw ParseError(message: "'\(text)': unknown key '\(keyName)'")
        }
        guard !modifiers.isEmpty else {
            throw ParseError(message: "'\(text)': a global shortcut needs at least one modifier")
        }
        return Hotkey(code, modifiers)
    }

    /// Inverse of `parse`, e.g. "ctrl+shift+left".
    public var configName: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [Self.names[keyCode] ?? "key\(keyCode)"]).joined(separator: "+")
    }
}

public enum HotkeyAction: Hashable, Sendable {
    case layout(LayoutCommand)
    case workspace(Int)
    case moveToWorkspace(Int)
    /// Opens a switcher session (⌃Tab); the same key with ⇧ opens it backwards.
    /// The session lasts while the binding's modifiers stay held.
    case switcher
    /// Same, limited to the windows of the frontmost app (⌃`).
    case switcherSameApp
    /// Focus the neighbour window in that direction (⌃⌥ arrows).
    case focus(Direction)
    /// Resize a tiled window: right / down grow it, left / up shrink it (⌃⌥⇧ arrows).
    case resize(Direction)
    /// Floating ⇄ tiled for the focused window (⌃⇧Space, i3's convention).
    case toggleFloating
    /// Pick the zone layout of the screen (⌃⇧Z); grabbed only while zones are on.
    case zonePicker
    /// Pick a saved arrangement of windows to restore (⌃⇧A).
    case arrangementPicker
}

extension String {
    /// Leading and trailing spaces and tabs removed (PaveCore stays Foundation-free).
    var trimmedSpaces: String {
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        guard let start = firstIndex(where: { !isSpace($0) }), let end = lastIndex(where: { !isSpace($0) }) else {
            return ""
        }
        return String(self[start...end])
    }
}
