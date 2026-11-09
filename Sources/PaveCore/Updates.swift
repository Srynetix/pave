import Foundation

/// Pavé's own updates, the pure part: which of a repository's GitHub releases
/// are Pavé's, which is newer, which file installs. Pavé reads them with `gh`
/// (PaveMac), so a private repository works with the access the user has.
///
/// A release is tagged `pave-v<version>` (`scripts/release.sh`) and carries
/// `Pave_<version>.dmg` (a first install), `Pave_<version>.app.tar.gz` (what an
/// update replaces), each with its `.sha256` and `.minisig`.
public enum Updates {
    public static let tagPrefix = "pave-v"
    public static let defaultSource = "Srynetix/pave"

    public struct Release: Equatable, Sendable {
        public var version: String
        public var tag: String
        public var notes: String
        /// Its page on GitHub.
        public var url: String
        public var assets: [Asset]

        public init(version: String, tag: String, notes: String = "", url: String = "", assets: [Asset] = []) {
            self.version = version
            self.tag = tag
            self.notes = notes
            self.url = url
            self.assets = assets
        }

        /// The archive an update installs, and its signature.
        public var archive: (file: Asset, signature: Asset)? {
            let name = Updates.archiveName(version)
            guard let file = assets.first(where: { $0.name == name }),
                let signature = assets.first(where: { $0.name == name + ".minisig" })
            else { return nil }
            return (file, signature)
        }
    }

    public struct Asset: Equatable, Sendable {
        public var name: String
        /// GitHub's asset ID: `repos/<repo>/releases/assets/<id>`.
        public var id: Int
        public init(name: String, id: Int) {
            self.name = name
            self.id = id
        }
    }

    public static func archiveName(_ version: String) -> String { "Pave_\(version).app.tar.gz" }

    /// `owner/repo`.
    public static func isValidSource(_ source: String) -> Bool {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            // At least a letter or digit: never "." or "..".
            part.contains { $0.isLetter || $0.isNumber } && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        }
    }

    /// Pavé's releases in GitHub's answer to `repos/<repo>/releases`: tagged
    /// `pave-v<version>`, drafts and pre-releases left out, newest first.
    public static func releases(fromGitHub json: Data) throws -> [Release] {
        struct R: Decodable {
            var tag_name: String
            var body: String?
            var html_url: String?
            var draft: Bool?
            var prerelease: Bool?
            var assets: [A]?
        }
        struct A: Decodable {
            var name: String
            var id: Int
        }
        let list = try JSONDecoder().decode([R].self, from: json)
        return list.compactMap { r -> Release? in
            guard r.draft != true, r.prerelease != true, r.tag_name.hasPrefix(tagPrefix) else { return nil }
            let version = String(r.tag_name.dropFirst(tagPrefix.count))
            guard Version(version) != nil else { return nil }
            return Release(
                version: version, tag: r.tag_name, notes: r.body ?? "", url: r.html_url ?? "",
                assets: (r.assets ?? []).map { Asset(name: $0.name, id: $0.id) })
        }
        .sorted { Version($0.version)! > Version($1.version)! }
    }

    /// The releases newer than `current`, newest first.
    public static func newer(_ releases: [Release], than current: String) -> [Release] {
        guard let now = Version(current) else { return [] }
        return releases.filter { Version($0.version).map { $0 > now } ?? false }
    }
}

/// `0.4.0`, `1.2`: dot-separated numbers, compared one by one (missing = 0).
public struct Version: Comparable, Sendable, CustomStringConvertible {
    public var parts: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.map { $0! }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
