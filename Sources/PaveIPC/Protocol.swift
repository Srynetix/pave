import Foundation
import PaveCore

/// One request per connection: a single JSON line, answered by a single JSON document.
public struct IPCRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case dump
        case restoreAll = "restore-all"
        case layout
        case workspace
        case moveToWorkspace = "move-to-workspace"
        /// Effective configuration and the state of the config file.
        case config
        /// Bring `window` to the front through FocusService (same path as the switcher).
        case focus
        case keyboards
        /// Development tools (debug builds): `args` holds the sub-command and its arguments.
        case spike
        /// Tiling: `args` holds the sub-command ("toggle", "on", "off",
        /// "float", "orientation", "focus left", "resize right", "move up").
        case tiling
        /// Zones: `args` holds the sub-command ("", "set S L", "edit [S] [L]", "on", "off").
        case zones
        /// Arrangements: `args` holds "", "save NAME", "restore NAME" or "delete NAME".
        case arrangement
        /// Pavé's updates: `args` holds "check" (default) or "install".
        case update
    }

    public var command: Command
    /// Include window titles in the answer. Off by default: titles can hold
    /// confidential data (mail subjects, customer or document names).
    public var showTitles: Bool
    /// For `.layout`.
    public var layout: LayoutCommand?
    /// Target window for `.layout` / `.moveToWorkspace`; the focused window when nil.
    public var window: UInt32?
    /// For `.workspace` / `.moveToWorkspace`.
    public var workspace: Int?
    /// Sub-command and arguments, for `.spike`, `.tiling`, `.zones`, `.arrangement`, `.update`.
    public var args: [String]?
    /// For `.workspace`: the screen to show it on (`--screen`).
    public var screen: String?

    public init(
        command: Command, showTitles: Bool = false, layout: LayoutCommand? = nil, window: UInt32? = nil,
        workspace: Int? = nil, args: [String]? = nil, screen: String? = nil
    ) {
        self.screen = screen
        self.command = command
        self.showTitles = showTitles
        self.layout = layout
        self.window = window
        self.workspace = workspace
        self.args = args
    }
}

public struct IPCResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var dump: Dump?
    public var move: MoveResult?
    public var message: String?

    public init(ok: Bool, error: String? = nil, dump: Dump? = nil, move: MoveResult? = nil, message: String? = nil) {
        self.ok = ok
        self.error = error
        self.dump = dump
        self.move = move
        self.message = message
    }

    public static func success(dump: Dump? = nil) -> IPCResponse { IPCResponse(ok: true, dump: dump) }
    public static func failure(_ message: String) -> IPCResponse { IPCResponse(ok: false, error: message) }
}

/// Everything Pavé knows, as printed by `pave dump`.
public struct Dump: Codable, Sendable, Equatable {
    public struct App: Codable, Sendable, Equatable {
        public var pid: PID
        public var name: String
        public var responsive: Bool
        public var bundleID: String?
        /// App rule in effect (`[apps."…"]`): "ignore", "no drag-snap", nil = none.
        public var rule: String?

        public init(pid: PID, name: String, responsive: Bool, bundleID: String? = nil, rule: String? = nil) {
            self.pid = pid
            self.name = name
            self.responsive = responsive
            self.bundleID = bundleID
            self.rule = rule
        }
    }

    public struct Window: Codable, Sendable, Equatable {
        public var id: UInt32
        public var pid: PID
        public var app: String
        /// nil unless titles were requested.
        public var title: String?
        public var titleLength: Int
        public var frame: Rect
        public var state: WindowState
        public var subrole: String
        public var workspace: Int?
        /// Parked off screen (window of an inactive workspace).
        public var hidden: Bool
        /// Why Pavé would not place it (dialog, app rule), nil if it would.
        public var notPlaced: String?
    }

    public var build: String
    public var activeWorkspace: Int?
    /// Workspace shown on each screen, by display UUID.
    public var visibleWorkspaces: [String: Int]?
    /// Tiling tree of each tiled workspace, e.g. "H[#12 V[#13 #14]]".
    public var tiling: [String: String]?
    /// Zone layout of each screen, by display UUID, when zones are on.
    public var zones: [String: String]?
    public var apps: [App]
    /// Most recently used first (the future Alt+Tab order).
    public var windows: [Window]

    public init(
        store: WindowStore, apps: [App], build: String, showTitles: Bool, workspaces: Workspaces? = nil,
        notPlaced: (WindowSnapshot) -> String? = { _ in nil }
    ) {
        self.activeWorkspace = workspaces?.active
        self.visibleWorkspaces = workspaces.map(\.visible).flatMap { $0.isEmpty ? nil : $0 }
        self.build = build
        self.apps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.windows = store.orderedWindows.map {
            Window(
                id: $0.id.rawValue, pid: $0.pid, app: $0.appName,
                title: showTitles ? $0.title : nil, titleLength: $0.title.count,
                frame: $0.frame, state: $0.state, subrole: $0.subrole,
                workspace: workspaces?.workspace(of: $0.id), hidden: workspaces?.isHidden($0.id) ?? false,
                notPlaced: notPlaced($0))
        }
    }
}

public enum IPCPaths {
    /// `$PAVE_SOCKET`, or ~/.local/state/pave/pave.sock.
    public static var socket: String {
        if let custom = ProcessInfo.processInfo.environment["PAVE_SOCKET"], !custom.isEmpty {
            return custom
        }
        return StateFiles.url("pave.sock").path
    }
}

public enum IPCCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return encoder
    }
}
