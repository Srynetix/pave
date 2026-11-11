// SPDX-License-Identifier: MIT OR Apache-2.0
// `pave`: command-line client of the Pavé agent, over its Unix socket.
import Foundation
import PaveCore
import PaveIPC

let usage = """
    usage: pave <command> [options]

    commands:
      dump [--titles]   print what Pavé knows (apps, windows in MRU order) as JSON.
                        Window titles are hidden unless --titles is given: they can
                        contain confidential data, keep them local.
      snap left|right   snap a window to the left/right half of its screen
      maximize          fill the usable area; from a half, its top quarter
      restore           from a half, its bottom quarter; from a top quarter, the
                        half; from maximized, the frame before Pavé placed it;
                        else minimize (Windows 11 behaviour, as Win+arrows)
      screen left|right send a window to the neighbour screen, same placement
                        (layout commands act on the focused window, or on
                        --window ID as listed by `pave dump`)
      workspace N [--screen S]  switch to virtual workspace N (1…9); with
                    --screen, show it on that screen (its number, 0 = main,
                    part of its name, or builtin), which becomes its home
      move-to N         send a window to workspace N (focused one, or --window ID)
      focus --window ID bring that window to the front (same path as the switcher)
      tiling [on|off|toggle] tile the active workspace or not (writes workspaces.tiling)
      tiling float      floating ⇄ tiled for a window (focused one, or --window ID)
      tiling orientation  flip the orientation of the focused window's container
      tiling focus|resize|move left|right|up|down   as ⌃⌥, ⌃⌥⇧ and ⌃ + arrows
      zones             zone layouts: on or off, each screen's layout, the
                        workspace overrides and the user's layouts
      zones set S L     use layout L (or "none") on screen S (its number,
                        builtin, part of its name, or its UUID); windows in
                        zones follow it
      zones edit [S] [L]  open the zone editor on screen S (else the one under
                        the mouse), from layout L (else the screen's)
      zones on|off      turn zones on or off (writes zones.enabled)
      arrangement       list the saved window arrangements
      arrangement save|restore|delete NAME   save the open windows (app, rank,
                        workspace, place: no title), put them back (launching
                        apps with no window), or forget an arrangement
      update [check]    look for a newer Pavé (GitHub releases of updates.source,
                        read with gh) and show what it brings
      update install    install it (signature checked) and restart Pavé
      config            show the config file path, whether it loaded, and the
                        settings in effect (edit the file: Pavé reloads it)
      apps              list the running apps with their bundle ID (as used in
                        [apps."<bundle id>"] rules) and the rule in effect
      restore-dock      put back the Dock settings Pavé saved before hiding it
                        (works without Pavé: after a crash). The Dock restarts.
      keyboards         list the connected keyboards (name, "vendor:product" as
                        used by keyboard.skip) and whether Pavé remapped them
      restore-all       bring every parked window back on screen. If Pavé is not
                        running, it is launched first: at start-up it restores the
                        windows a crashed run left parked (state.json)

    environment:
      PAVE_SOCKET       socket path (default ~/.local/state/pave/pave.sock)
      PAVE_CONFIG       config file read by Pavé (default ~/.config/pave/config.toml)
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("pave: \(message)\n".utf8))
    exit(code)
}

/// Launches Pave.app through LaunchServices (so it runs with its own
/// Accessibility permission) and waits for its socket.
func launchPave(timeout: TimeInterval = 8) -> Bool {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-b", "dev.srynetix.pave.Pave"]
    guard (try? open.run()) != nil else { return false }
    open.waitUntilExit()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let fd = try? UnixSocket.connect(path: IPCPaths.socket, timeout: 1) {
            close(fd)
            return true
        }
        usleep(200_000)
    }
    return false
}

func send(_ request: IPCRequest, launchIfNeeded: Bool = false) -> IPCResponse {
    let path = IPCPaths.socket
    let fd: Int32
    do {
        fd = try UnixSocket.connect(path: path)
    } catch let error as SocketError where error.code == ENOENT || error.code == ECONNREFUSED {
        if launchIfNeeded {
            FileHandle.standardError.write(Data("pave: Pavé is not running, launching it…\n".utf8))
            guard launchPave() else { fail("could not launch Pavé (bundle id dev.srynetix.pave.Pave)") }
            return send(request)
        }
        fail("Pavé is not running (no socket at \(path)). Start it with `just dev`.")
    } catch {
        fail("\(error)")
    }
    defer { close(fd) }

    guard var data = try? IPCCoding.encoder().encode(request) else { fail("cannot encode request") }
    data.append(UInt8(ascii: "\n"))
    UnixSocket.writeAll(fd, data)
    shutdown(fd, SHUT_WR)

    let answer = UnixSocket.readAll(fd)
    guard let response = try? JSONDecoder().decode(IPCResponse.self, from: answer) else {
        fail("invalid response from Pavé (\(answer.count) bytes)")
    }
    return response
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

/// Removes `--window ID` from the remaining arguments.
@MainActor
func takeWindowOption() -> UInt32? {
    guard let i = args.firstIndex(of: "--window") else { return nil }
    guard i + 1 < args.count, let id = UInt32(args[i + 1]) else { fail("--window needs a window id", code: 2) }
    args.removeSubrange(i...(i + 1))
    return id
}

/// Same as DockController.restore, without Pavé running.
func restoreDock() -> Never {
    let state = StateFiles.url("dock.json")
    guard let data = FileManager.default.contents(atPath: state.path),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let saved = json["saved"] as? [String: Any]
    else {
        print("nothing to restore: Pavé has not hidden the Dock (\(state.path) does not exist)")
        exit(0)
    }
    let domain = "com.apple.dock" as CFString
    // An older state file covers only the first two keys.
    for key in json["keys"] as? [String] ?? ["autohide", "autohide-delay"] {
        CFPreferencesSetAppValue(key as CFString, saved[key].map { $0 as CFPropertyList }, domain)
    }
    CFPreferencesAppSynchronize(domain)
    let killall = Process()
    killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    killall.arguments = ["Dock"]
    try? killall.run()
    killall.waitUntilExit()
    try? FileManager.default.removeItem(at: state)
    print("Dock settings restored (\(saved.keys.sorted().joined(separator: ", ")); keys Pavé added were removed)")
    print("note: if Pavé runs with taskbar.hide-dock = true, it hides the Dock again; turn that setting off first")
    exit(0)
}

let request: IPCRequest
var listApps = false
switch command {
case "-h", "--help", "help":
    print(usage)
    exit(0)
case "dump":
    let unknown = args.filter { $0 != "--titles" }
    if !unknown.isEmpty { fail("unknown option(s) for dump: \(unknown.joined(separator: " "))", code: 2) }
    request = IPCRequest(command: .dump, showTitles: args.contains("--titles"))
case "restore-all":
    request = IPCRequest(command: .restoreAll)
case "config":
    request = IPCRequest(command: .config)
case "apps":
    request = IPCRequest(command: .dump)
    listApps = true
case "restore-dock":
    restoreDock()
case "keyboards":
    request = IPCRequest(command: .keyboards)
case "focus":
    guard let window = takeWindowOption(), args.isEmpty else { fail("usage: pave focus --window ID", code: 2) }
    request = IPCRequest(command: .focus, window: window)
case "workspace":
    var screen: String?
    if let i = args.firstIndex(of: "--screen") {
        guard i + 1 < args.count else {
            fail("--screen needs a screen: its number (0 = main), part of its name, or builtin", code: 2)
        }
        screen = args[i + 1]
        args.removeSubrange(i...(i + 1))
    }
    guard args.count == 1, let n = Int(args[0]) else { fail("usage: pave workspace N [--screen S]", code: 2) }
    request = IPCRequest(command: .workspace, workspace: n, screen: screen)
case "move-to":
    let window = takeWindowOption()
    guard args.count == 1, let n = Int(args[0]) else { fail("usage: pave move-to N [--window ID]", code: 2) }
    request = IPCRequest(command: .moveToWorkspace, window: window, workspace: n)
case "tiling":
    let window = takeWindowOption()
    if case .failure(let usage) = TilingCommand.parse(args) { fail(usage.description, code: 2) }
    request = IPCRequest(command: .tiling, window: window, args: args)
case "zones":
    if case .failure(let usage) = ZonesCommand.parse(args) { fail(usage.description, code: 2) }
    request = IPCRequest(command: .zones, args: args)
case "update":
    if case .failure(let usage) = UpdateCommand.parse(args) { fail(usage.description, code: 2) }
    request = IPCRequest(command: .update, args: args)
case "arrangement", "arrangements":
    if case .failure(let usage) = ArrangementCommand.parse(args) { fail(usage.description, code: 2) }
    request = IPCRequest(command: .arrangement, args: args)
case "spike":
    let window = takeWindowOption()
    request = IPCRequest(command: .spike, window: window, args: args)
case "screen":
    let window = takeWindowOption()
    let layout: LayoutCommand
    switch args.first {
    case "left": layout = .moveToScreenLeft
    case "right": layout = .moveToScreenRight
    default: fail("usage: pave screen left|right [--window ID]", code: 2)
    }
    request = IPCRequest(command: .layout, layout: layout, window: window)
case "snap", "maximize", "restore":
    let window = takeWindowOption()
    let layout: LayoutCommand
    switch (command, args.first) {
    case ("snap", "left"): layout = .snapLeft
    case ("snap", "right"): layout = .snapRight
    case ("maximize", nil): layout = .maximize
    case ("restore", nil): layout = .restore
    default: fail("usage: pave snap left|right | maximize | restore [--window ID]", code: 2)
    }
    request = IPCRequest(command: .layout, layout: layout, window: window)
default:
    fail("unknown command '\(command)'. See `pave --help`.", code: 2)
}

let response = send(request, launchIfNeeded: request.command == .restoreAll)
guard response.ok else { fail(response.error ?? "unknown error") }
if listApps, let dump = response.dump {
    let width = dump.apps.map(\.name.count).max() ?? 0
    for app in dump.apps {
        let name = app.name.padding(toLength: width, withPad: " ", startingAt: 0)
        print("\(name)  \(app.bundleID ?? "(no bundle id)")" + (app.rule.map { "  [\($0)]" } ?? ""))
    }
    exit(0)
}
if let dump = response.dump, let json = try? IPCCoding.encoder(pretty: true).encode(dump) {
    print(String(decoding: json, as: UTF8.self))
}
if let move = response.move, let json = try? IPCCoding.encoder(pretty: true).encode(move) {
    print(String(decoding: json, as: UTF8.self))
    if !move.ok { exit(3) }
}
if let message = response.message { print(message) }
