/// Minimal TOML reader for Pavé's config file (`ConfigStore`).
///
/// Supported subset, enough for `config.toml`: `[table]` and `[dotted.table]`
/// headers, bare or quoted keys, basic ("…", with \" \\ \n \t escapes) and
/// literal ('…') strings, integers, booleans, arrays of those (on one or
/// several lines), `#` comments. Not supported (reported as errors): inline
/// tables, arrays of tables, floats, dates, multi-line strings, dotted keys.
/// Pure Swift, no dependency.
public enum TOMLValue: Equatable, Sendable, CustomStringConvertible {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    public var description: String {
        switch self {
        case .string(let s): "\"\(s)\""
        case .integer(let i): "\(i)"
        case .bool(let b): "\(b)"
        case .array(let a): "[" + a.map(\.description).joined(separator: ", ") + "]"
        case .table: "table"
        }
    }

    /// The value as error messages show it: numbers and booleans as they
    /// are, never the text of a string. Messages reach the log, `pave config`
    /// and Settings, and a string may be private (a workspace name).
    public var shown: String {
        switch self {
        case .string: "a string"
        case .integer(let i): "\(i)"
        case .bool(let b): "\(b)"
        case .array(let a): a.isEmpty ? "an empty list" : "a list of \(a.count) item\(a.count == 1 ? "" : "s")"
        case .table: "a table"
        }
    }

    /// Human name of the type, for error messages.
    public var typeName: String {
        switch self {
        case .string: "string"
        case .integer: "integer"
        case .bool: "boolean"
        case .array: "array"
        case .table: "table"
        }
    }
}

public struct TOMLError: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var message: String
    public var description: String { "line \(line): \(message)" }
}

public enum TOML {
    /// Parses `text` into its root table. Every value also remembers the line it
    /// was defined on, in `lines` (key path "table.key" → line), for later errors.
    public static func parse(_ text: String) throws(TOMLError) -> (root: [String: TOMLValue], lines: [String: Int]) {
        var parser = Parser(text)
        try parser.run()
        return (parser.root, parser.lines)
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        var line = 1
        var root: [String: TOMLValue] = [:]
        var lines: [String: Int] = [:]
        var tablePath: [String] = []
        var definedTables: Set<String> = []

        init(_ text: String) { chars = Array(text) }

        var atEnd: Bool { i >= chars.count }
        var current: Character? { atEnd ? nil : chars[i] }

        func fail(_ message: String) -> TOMLError { TOMLError(line: line, message: message) }

        mutating func advance() {
            if chars[i] == "\n" { line += 1 }
            i += 1
        }

        mutating func skipSpaces() {
            while let c = current, c == " " || c == "\t" { advance() }
        }

        /// Spaces, newlines and comments (inside arrays and between statements).
        mutating func skipBlank() {
            while let c = current {
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    advance()
                } else if c == "#" {
                    while let d = current, d != "\n" { advance() }
                } else {
                    return
                }
            }
        }

        /// After a statement: only spaces and a comment may follow on the line.
        mutating func endOfLine() throws(TOMLError) {
            skipSpaces()
            if current == "#" { while let c = current, c != "\n" { advance() } }
            if current == "\r" { advance() }
            guard atEnd || current == "\n" else { throw fail("unexpected '\(current!)' after value") }
        }

        mutating func run() throws(TOMLError) {
            while true {
                skipBlank()
                guard let c = current else { return }
                if c == "[" {
                    try header()
                } else {
                    try keyValue()
                }
                try endOfLine()
            }
        }

        mutating func header() throws(TOMLError) {
            advance()  // [
            if current == "[" { throw fail("arrays of tables ([[…]]) are not supported") }
            var path: [String] = []
            while true {
                skipSpaces()
                path.append(try key())
                skipSpaces()
                if current == "." { advance(); continue }
                guard current == "]" else { throw fail("expected ']' to close the table header") }
                advance()
                break
            }
            let name = path.joined(separator: ".")
            lines[name] = line
            guard definedTables.insert(name).inserted else { throw fail("table [\(name)] defined twice") }
            // Create the table (and its parents) so empty tables exist too.
            try insert(path: path, value: nil)
            tablePath = path
        }

        mutating func keyValue() throws(TOMLError) {
            let startLine = line
            let name = try key()
            skipSpaces()
            if current == "." { throw fail("dotted keys are not supported, use a [table] header") }
            guard current == "=" else { throw fail("expected '=' after key '\(name)'") }
            advance()
            skipSpaces()
            let value = try self.value()
            let path = tablePath + [name]
            try insert(path: path, value: value)
            lines[path.joined(separator: ".")] = startLine
        }

        mutating func key() throws(TOMLError) -> String {
            guard let c = current else { throw fail("expected a key") }
            if c == "\"" { return try basicString() }
            if c == "'" { return try literalString() }
            var name = ""
            while let d = current, d.isLetter || d.isNumber || d == "_" || d == "-" {
                name.append(d)
                advance()
            }
            guard !name.isEmpty else { throw fail("expected a key, found '\(c)'") }
            return name
        }

        mutating func value() throws(TOMLError) -> TOMLValue {
            guard let c = current else { throw fail("expected a value") }
            switch c {
            case "\"": return .string(try basicString())
            case "'": return .string(try literalString())
            case "[": return try array()
            case "{": throw fail("inline tables are not supported, use a [table] header")
            default:
                var word = ""
                while let d = current, !" \t\n\r,]#".contains(d) {
                    word.append(d)
                    advance()
                }
                if word == "true" { return .bool(true) }
                if word == "false" { return .bool(false) }
                if let n = Int(String(word.filter { $0 != "_" })) { return .integer(n) }
                throw fail(word.isEmpty ? "expected a value" : "unsupported value (strings need quotes)")
            }
        }

        mutating func array() throws(TOMLError) -> TOMLValue {
            advance()  // [
            var items: [TOMLValue] = []
            while true {
                skipBlank()
                if current == "]" { advance(); return .array(items) }
                items.append(try value())
                skipBlank()
                if current == "," { advance(); continue }
                guard current == "]" else { throw fail("expected ',' or ']' in array") }
                advance()
                return .array(items)
            }
        }

        mutating func basicString() throws(TOMLError) -> String {
            advance()  // "
            if current == "\"", i + 1 < chars.count, chars[i + 1] == "\"" {
                throw fail("multi-line strings are not supported")
            }
            var s = ""
            while let c = current {
                switch c {
                case "\"":
                    advance()
                    return s
                case "\n":
                    throw fail("unterminated string")
                case "\\":
                    advance()
                    guard let e = current else { throw fail("unterminated string") }
                    switch e {
                    case "\"": s.append("\"")
                    case "\\": s.append("\\")
                    case "n": s.append("\n")
                    case "t": s.append("\t")
                    default: throw fail("unsupported escape '\\\(e)'")
                    }
                    advance()
                default:
                    s.append(c)
                    advance()
                }
            }
            throw fail("unterminated string")
        }

        mutating func literalString() throws(TOMLError) -> String {
            advance()  // '
            var s = ""
            while let c = current {
                if c == "'" { advance(); return s }
                if c == "\n" { break }
                s.append(c)
                advance()
            }
            throw fail("unterminated string")
        }

        /// Inserts `value` at `path` (nil: just make sure the tables exist).
        mutating func insert(path: [String], value: TOMLValue?) throws(TOMLError) {
            func place(_ table: inout [String: TOMLValue], _ rest: ArraySlice<String>) throws(TOMLError) {
                let head = rest.first!
                if rest.count == 1, let value {
                    guard table[head] == nil else { throw fail("key '\(path.joined(separator: "."))' defined twice") }
                    table[head] = value
                    return
                }
                var child: [String: TOMLValue]
                switch table[head] {
                case nil: child = [:]
                case .table(let t): child = t
                case let other?: throw fail("'\(head)' is a \(other.typeName), not a table")
                }
                if rest.count > 1 { try place(&child, rest.dropFirst()) }
                table[head] = .table(child)
            }
            var updated = root
            try place(&updated, path[...])
            root = updated
        }
    }
}
