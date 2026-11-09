/// A saved arrangement of windows ("Code", "Meeting"): where each window of
/// each app goes, and on which workspace. Pure.
///
/// Windows are recognised **by app and order** only: the n-th window of an
/// app (by creation) takes the n-th place saved for that app. No title is
/// ever stored: they can hold confidential data, and this goes to a file.
public struct Arrangement: Codable, Equatable, Sendable {
    public struct Place: Codable, Equatable, Sendable {
        /// Bundle ID of the app.
        public var app: String
        /// Rank among that app's windows, by creation (0 = oldest).
        public var index: Int
        /// Nil when workspaces were off.
        public var workspace: Int?
        /// Display UUID of the screen it was on.
        public var screen: String
        /// Its frame (the frame it will have when shown, for a parked window).
        public var frame: Rect
        /// The zones it filled, when its screen had a layout: preferred to
        /// `frame` if the screen still has one.
        public var zones: [Int]?

        public init(app: String, index: Int, workspace: Int?, screen: String, frame: Rect, zones: [Int]? = nil) {
            self.app = app
            self.index = index
            self.workspace = workspace
            self.screen = screen
            self.frame = frame
            self.zones = zones
        }
    }

    public var name: String
    public var places: [Place]

    public init(name: String, places: [Place]) {
        self.name = name
        self.places = places
    }

    /// A window as the matching sees it: its app and its ID (creation order).
    public struct Candidate: Equatable, Sendable {
        public var id: WindowID
        public var app: String
        public init(id: WindowID, app: String) {
            self.id = id
            self.app = app
        }
    }

    /// Which open window takes which place, and the places left with no window.
    public struct Match: Equatable, Sendable {
        public var placed: [(window: WindowID, place: Place)]
        /// Places of apps with fewer open windows than saved, in order.
        public var waiting: [Place]
        /// Apps with no window at all: to launch.
        public var appsToLaunch: [String]

        public static func == (a: Match, b: Match) -> Bool {
            a.placed.map(\.window) == b.placed.map(\.window) && a.placed.map(\.place) == b.placed.map(\.place)
                && a.waiting == b.waiting && a.appsToLaunch == b.appsToLaunch
        }
    }

    /// The n-th window of an app (by ID, which grows with creation) takes the
    /// n-th place of that app.
    public func match(_ windows: [Candidate]) -> Match {
        let byApp = Dictionary(grouping: windows, by: \.app).mapValues { $0.sorted { $0.id.rawValue < $1.id.rawValue } }
        var placed: [(WindowID, Place)] = []
        var waiting: [Place] = []
        var launch: [String] = []
        for place in places.sorted(by: { ($0.app, $0.index) < ($1.app, $1.index) }) {
            let open = byApp[place.app] ?? []
            if place.index < open.count {
                placed.append((open[place.index].id, place))
            } else {
                waiting.append(place)
                if open.isEmpty, !launch.contains(place.app) { launch.append(place.app) }
            }
        }
        return Match(placed: placed, waiting: waiting, appsToLaunch: launch)
    }

    /// Ranks the windows of each app by creation, as `match` does.
    public static func indices(of windows: [Candidate]) -> [WindowID: Int] {
        var result: [WindowID: Int] = [:]
        for (_, group) in Dictionary(grouping: windows, by: \.app) {
            for (i, w) in group.sorted(by: { $0.id.rawValue < $1.id.rawValue }).enumerated() { result[w.id] = i }
        }
        return result
    }

    /// A name the menu, the picker and the CLI can show: letters, digits,
    /// spaces, - and _, at most 40 characters.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && name.first != " " && name.last != " "
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
    }
}
