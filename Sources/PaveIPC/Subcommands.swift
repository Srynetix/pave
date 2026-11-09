import PaveCore

/// The sub-commands of `pave tiling | zones | arrangement | update`, parsed
/// once, here: the CLI checks them before sending (and prints the usage),
/// Pavé reads the same `args` back with the same parser.
public struct UsageError: Error, Equatable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum TilingCommand: Equatable, Sendable {
    case on, off, toggle, float, orientation
    case focus(Direction), resize(Direction), move(Direction)

    public static let usage = "usage: pave tiling [on|off|toggle|float|orientation|focus DIR|resize DIR|move DIR] (DIR: left right up down)"

    public static func parse(_ args: [String]) -> Result<TilingCommand, UsageError> {
        let direction = args.count == 2 ? Direction(rawValue: args[1]) : nil
        switch (args.first, args.count, direction) {
        case (nil, _, _), ("toggle", 1, _): return .success(.toggle)
        case ("on", 1, _): return .success(.on)
        case ("off", 1, _): return .success(.off)
        case ("float", 1, _): return .success(.float)
        case ("orientation", 1, _): return .success(.orientation)
        case ("focus", 2, let d?): return .success(.focus(d))
        case ("resize", 2, let d?): return .success(.resize(d))
        case ("move", 2, let d?): return .success(.move(d))
        default: return .failure(UsageError(usage))
        }
    }
}

public enum ZonesCommand: Equatable, Sendable {
    /// On or off, each screen's layout, the overrides and the layouts.
    case report
    case enable(Bool)
    case set(screen: String, layout: String)
    /// The screen under the mouse when nil; the screen's layout when nil.
    case edit(screen: String?, layout: String?)

    public static let usage = "usage: pave zones [set SCREEN LAYOUT | edit [SCREEN] [LAYOUT] | on | off]"

    public static func parse(_ args: [String]) -> Result<ZonesCommand, UsageError> {
        switch args.first {
        case nil: return .success(.report)
        case "on" where args.count == 1: return .success(.enable(true))
        case "off" where args.count == 1: return .success(.enable(false))
        case "set":
            guard args.count == 3 else { return .failure(UsageError("usage: pave zones set SCREEN LAYOUT")) }
            return .success(.set(screen: args[1], layout: args[2]))
        case "edit":
            guard args.count <= 3 else { return .failure(UsageError("usage: pave zones edit [SCREEN] [LAYOUT]")) }
            return .success(.edit(screen: args.count >= 2 ? args[1] : nil, layout: args.count == 3 ? args[2] : nil))
        default: return .failure(UsageError(usage))
        }
    }
}

public enum ArrangementCommand: Equatable, Sendable {
    case list
    case save(String), restore(String), delete(String)

    public static let usage = "usage: pave arrangement [list | save NAME | restore NAME | delete NAME]"

    /// The name is every word after the verb ("Morning code").
    public static func parse(_ args: [String]) -> Result<ArrangementCommand, UsageError> {
        let name = args.dropFirst().joined(separator: " ")
        switch args.first {
        case nil, "list": return args.count <= 1 ? .success(.list) : .failure(UsageError(usage))
        case "save":
            guard Arrangement.isValidName(name) else {
                return .failure(UsageError("usage: pave arrangement save NAME (letters, digits, spaces, - or _)"))
            }
            return .success(.save(name))
        case "restore" where !name.isEmpty: return .success(.restore(name))
        case "delete" where !name.isEmpty: return .success(.delete(name))
        default: return .failure(UsageError(usage))
        }
    }
}

public enum UpdateCommand: Equatable, Sendable {
    case check, install

    public static let usage = "usage: pave update [check|install]"

    public static func parse(_ args: [String]) -> Result<UpdateCommand, UsageError> {
        switch (args.first, args.count) {
        case (nil, _), ("check", 1): return .success(.check)
        case ("install", 1): return .success(.install)
        default: return .failure(UsageError(usage))
        }
    }
}
