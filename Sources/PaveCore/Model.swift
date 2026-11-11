// SPDX-License-Identifier: MIT OR Apache-2.0
/// Process identifier (mirrors `pid_t` without importing Darwin).
public typealias PID = Int32

/// Stable identity of a window for its whole lifetime: the WindowServer's CGWindowID.
public struct WindowID: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible
{
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (a: WindowID, b: WindowID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { "#\(rawValue)" }
}

public enum WindowState: String, Sendable, Codable {
    case normal, minimized, hidden, fullscreen
}

/// What the Accessibility API told us about one window at a given time.
public struct WindowSnapshot: Equatable, Sendable, Codable {
    public var id: WindowID
    public var pid: PID
    public var appName: String
    public var title: String
    public var frame: Rect
    public var state: WindowState
    /// AX subrole, e.g. "AXStandardWindow", "AXDialog".
    public var subrole: String
    /// False for a window without an enabled minimize button: the Open and Save
    /// panels and settings windows, which call themselves standard windows (M4, A3).
    /// Nil: not read (not a standard window, or its app is hidden).
    public var minimizable: Bool?

    public init(
        id: WindowID, pid: PID, appName: String, title: String, frame: Rect,
        state: WindowState, subrole: String, minimizable: Bool? = nil
    ) {
        self.minimizable = minimizable
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.frame = frame
        self.state = state
        self.subrole = subrole
    }
}

/// Full picture of one application's windows, taken in one pass on its AX thread.
public struct AppSnapshot: Equatable, Sendable {
    public var pid: PID
    public var windows: [WindowSnapshot]
    /// The app's own focused window (meaningful for the user only if the app is frontmost).
    public var focusedWindow: WindowID?

    public init(pid: PID, windows: [WindowSnapshot], focusedWindow: WindowID?) {
        self.pid = pid
        self.windows = windows
        self.focusedWindow = focusedWindow
    }
}

public enum WindowChange: Equatable, Sendable, CustomStringConvertible {
    case created(WindowSnapshot)
    case destroyed(WindowSnapshot)
    case frameChanged(WindowID, from: Rect, to: Rect)
    case retitled(WindowID, from: String, to: String)
    case stateChanged(WindowID, from: WindowState, to: WindowState)
    case focused(WindowID)

    /// Window titles can hold confidential data (mail subjects, document and
    /// customer names): logs show them redacted unless explicitly asked.
    public var description: String { describe(showTitles: false) }

    public func describe(showTitles: Bool) -> String {
        func t(_ title: String) -> String { showTitles ? "\"\(title)\"" : "<title:\(title.count)>" }
        return switch self {
        case .created(let w): "created \(w.id) [\(w.appName)] \(t(w.title)) \(w.frame) \(w.state.rawValue)"
        case .destroyed(let w): "destroyed \(w.id) [\(w.appName)] \(t(w.title))"
        case .frameChanged(let id, let from, let to): "frame \(id) \(from) → \(to)"
        case .retitled(let id, let from, let to): "title \(id) \(t(from)) → \(t(to))"
        case .stateChanged(let id, let from, let to): "state \(id) \(from.rawValue) → \(to.rawValue)"
        case .focused(let id): "focus \(id)"
        }
    }
}
