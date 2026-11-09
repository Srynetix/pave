/// The Start button's app launcher: which apps match what
/// was typed, best first. Pure; PaveMac lists the apps and launches them.
public enum Launcher {
    public struct App: Equatable, Sendable {
        public var name: String
        /// Bundle path: identifies the app (two apps may share a name).
        public var path: String
        public init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    /// Matches for `query`, best first: name starting with it, then a word
    /// starting with it, then its letters in order; ties alphabetical. An
    /// empty query lists every app alphabetically. Case and accents ignored.
    public static func search(_ query: String, in apps: [App]) -> [App] {
        let needle = Search.fold(query.trimmedSpaces)
        let scored = apps.compactMap { app in Search.score(needle, name: app.name).map { (app, $0) } }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let (na, nb) = (Search.fold(a.0.name), Search.fold(b.0.name))
            return na != nb ? na.lexicographicallyPrecedes(nb) : a.0.path < b.0.path
        }.map(\.0)
    }
}
