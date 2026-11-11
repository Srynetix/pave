/// Changes one setting of a config file **as text** (menu toggles, Settings
/// window), so the user's comments, order and other settings stay untouched.
public enum ConfigEdit {
    /// Sets `table.key = value` (`value` already in TOML form: `true`, `"pc"`).
    /// - the key exists in `[table]`: that line is replaced (its trailing
    ///   comment is kept);
    /// - the table exists without the key: the line goes right after the header;
    /// - no table: `[table]` is appended at the end of the file.
    public static func set(_ table: String, _ key: String, to value: String, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inTable = false
        var header: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmedSpaces
            if trimmed.hasPrefix("[") {
                let name = String(trimmed.dropFirst().prefix { $0 != "]" }).trimmedSpaces
                inTable = name == table
                if inTable { header = index }
                continue
            }
            guard inTable, keyOf(trimmed) == key else { continue }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            lines[index] = indent + "\(key) = \(value)" + trailingComment(trimmed)
            return lines.joined(separator: "\n")
        }
        if let header {
            lines.insert("\(key) = \(value)", at: header + 1)
            return lines.joined(separator: "\n")
        }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result + "\n[\(table)]\n\(key) = \(value)\n"
    }

    /// Removes `table.key` (the default applies again). Nothing to do: `text` as is.
    public static func remove(_ table: String, _ key: String, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inTable = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmedSpaces
            if trimmed.hasPrefix("[") {
                inTable = tableName(trimmed) == table
                continue
            }
            if inTable, keyOf(trimmed) == key {
                lines.remove(at: index)
                return lines.joined(separator: "\n")
            }
        }
        return text
    }

    /// Removes `[table]` and its lines, up to the next table (an app rule).
    /// Comments right above the header stay: they may introduce something else.
    public static func removeTable(_ table: String, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard
            let start = lines.firstIndex(where: {
                $0.trimmedSpaces.hasPrefix("[") && tableName($0.trimmedSpaces) == table
            })
        else { return text }
        var end = start + 1
        while end < lines.count, !lines[end].trimmedSpaces.hasPrefix("[") { end += 1 }
        // Keep the blank line that separates the next table.
        while end > start + 1, lines[end - 1].trimmedSpaces.isEmpty, end < lines.count { end -= 1 }
        lines.removeSubrange(start..<end)
        if start > 0, start < lines.count, lines[start - 1].trimmedSpaces.isEmpty, lines[start].trimmedSpaces.isEmpty {
            lines.remove(at: start)
        }
        return lines.joined(separator: "\n")
    }

    /// A TOML basic string: `"Web"`, with `"` and `\` escaped.
    public static func string(_ value: String) -> String {
        var out = "\""
        for c in value {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    /// `["a", "b"]`.
    public static func list(_ values: [String]) -> String { "[" + values.map(string).joined(separator: ", ") + "]" }

    /// `[2, 3]`.
    public static func list(_ values: [Int]) -> String { "[" + values.map(String.init).joined(separator: ", ") + "]" }

    /// `apps."com.example.app"`: the header of an app rule.
    public static func appTable(_ bundleID: String) -> String { "apps.\"\(bundleID)\"" }

    private static func tableName(_ trimmedHeader: String) -> String {
        String(trimmedHeader.dropFirst().prefix { $0 != "]" }).trimmedSpaces
    }

    /// "enabled = false # x" → "enabled"; comments and blank lines → nil.
    private static func keyOf(_ line: String) -> String? {
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
        var name = String(line[..<eq]).trimmedSpaces
        if name.count >= 2, let first = name.first, first == "\"" || first == "'", name.last == first {
            name = String(name.dropFirst().dropLast())
        }
        return name
    }

    /// " # comment" after the value, if any (a `#` outside a string).
    private static func trailingComment(_ line: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return "" }
        var quote: Character?
        for index in line[line.index(after: eq)...].indices {
            let c = line[index]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return " " + line[index...]
            }
        }
        return ""
    }
}
