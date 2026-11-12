// SPDX-License-Identifier: MIT OR Apache-2.0
/// A window title pattern of an app rule (`[apps."…".titles]`): the whole
/// title must match, `*` stands for any text, `?` for one character, case
/// ignored. "*Work" matches a title ending with "work", "*pave*" one that
/// contains "pave". Titles are compared here, never logged.
public enum TitlePattern {
    public static func matches(_ pattern: String, _ title: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(title.lowercased())
        // Classic wildcard matching: on a mismatch, go back to the last `*`
        // and let it take one more character.
        var pi = 0
        var ti = 0
        var star: Int?
        var resume = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                star = pi
                resume = ti
                pi += 1
            } else if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if let star {
                pi = star + 1
                resume += 1
                ti = resume
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// The value of the most specific pattern `title` matches: the one with
    /// the most characters other than `*` ("*Home Work" before "*Work"), then
    /// the first in alphabetical order, so the choice never depends on the
    /// order of the file.
    public static func best<Value>(_ patterns: [String: Value], title: String) -> Value? {
        func weight(_ pattern: String) -> Int { pattern.filter { $0 != "*" }.count }
        return patterns.filter { matches($0.key, title) }
            .min { weight($0.key) != weight($1.key) ? weight($0.key) > weight($1.key) : $0.key < $1.key }?.value
    }
}
