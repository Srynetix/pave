/// One `key = value` of the config file as `PaveConfig.parse` reads it: its
/// path (`taskbar.grouping`), its value and its line, with the checks every
/// table repeats. Errors never show a string's text (`TOMLValue.shown`).
struct ConfigField {
    let path: String
    let value: TOMLValue
    let line: Int

    func problem(_ message: String) -> PaveConfig.Problem { .init(line: line, message: message) }

    func bool() throws(PaveConfig.Problem) -> Bool {
        guard case .bool(let b) = value else { throw problem("\(path) must be true or false, not \(value.shown)") }
        return b
    }

    /// `what`: "a number of points from 0 to 64".
    func integer(in range: ClosedRange<Int>, _ what: String) throws(PaveConfig.Problem) -> Int {
        guard case .integer(let n) = value, range.contains(n) else {
            throw problem("\(path) must be \(what), not \(value.shown)")
        }
        return n
    }

    /// One of an enum's raw values; `allowed` phrases them for the message.
    func choice<T: RawRepresentable>(_ type: T.Type, allowed: String) throws(PaveConfig.Problem) -> T
    where T.RawValue == String {
        guard case .string(let s) = value, let choice = T(rawValue: s) else {
            throw problem("\(path) must be \(allowed), not \(value.shown)")
        }
        return choice
    }

    /// One of `options`, as written.
    func string(oneOf options: [String], allowed: String) throws(PaveConfig.Problem) -> String {
        guard case .string(let s) = value, options.contains(s) else {
            throw problem("\(path) must be \(allowed), not \(value.shown)")
        }
        return s
    }

    /// A list whose items `item` converts (nil: refused with `usage`).
    func list<T>(_ usage: String, maxCount: Int = .max, _ item: (TOMLValue) -> T?) throws(PaveConfig.Problem) -> [T] {
        guard case .array(let items) = value, items.count <= maxCount else { throw problem(usage) }
        var result: [T] = []
        for raw in items {
            guard let converted = item(raw) else { throw problem("\(usage), not \(raw.shown)") }
            result.append(converted)
        }
        return result
    }
}

extension Array where Element == String {
    /// `"a", "b" or "c"`.
    var quotedChoices: String {
        let quoted = map { "\"\($0)\"" }
        return quoted.count > 1 ? quoted.dropLast().joined(separator: ", ") + " or " + quoted.last! : quoted.joined()
    }
}
