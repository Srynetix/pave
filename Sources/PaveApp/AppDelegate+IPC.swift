import AppKit
import PaveCore
import PaveIPC
import PaveMac
import ServiceManagement

/// The `pave` CLI: the socket server and every command.
extension AppDelegate {
    func startIPC() {
        let server = IPCServer { [weak self] request, reply in
            guard let self else { return reply(.failure("Pavé is shutting down")) }
            self.handle(request, reply: reply)
        }
        do {
            try server.start()
            ipc = server
        } catch {
            Log.info("IPC unavailable: \(error)")
        }
    }

    func handle(_ request: IPCRequest, reply: @escaping @Sendable (IPCResponse) -> Void) {
        let windowID = request.window.map { WindowID($0) }
        switch request.command {
        case .dump:
            let apps = registry.trackedApps.map { app in
                let id = bundleID(app.pid)
                return Dump.App(
                    pid: app.pid, name: app.name, responsive: app.responsive, bundleID: id,
                    rule: config.config.rule(for: id).summary)
            }
            var dump = Dump(
                store: registry.store, apps: apps, build: build, showTitles: request.showTitles,
                workspaces: workspaces.state,
                notPlaced: { [unowned self] w in self.commander.rule(w).refusal(for: w, via: .hotkey) })
            let trees = tiling.summary
            dump.tiling = trees.isEmpty ? nil : trees
            if config.config.zones.enabled {
                dump.zones = Dictionary(uniqueKeysWithValues: Screens.all().map { ($0.id, zones(on: $0, keyboard: true)?.layout.name ?? ZoneSettings.none) })
            }
            reply(.success(dump: dump))
        case .restoreAll:
            workspaces.restoreAll(source: "cli") { [weak self] count in
                self?.refresh()
                reply(IPCResponse(ok: true, message: "\(count) window(s) brought back"))
            }
        case .layout:
            guard let layout = request.layout else { return reply(.failure("missing layout command")) }
            commander.perform(layout, windowID: windowID, source: "cli") { outcome in
                if outcome.window == nil { return reply(.failure(outcome.message ?? "no window")) }
                reply(IPCResponse(ok: true, move: outcome.move, message: outcome.message))
            }
        case .workspace:
            guard let n = request.workspace else { return reply(.failure("missing workspace number")) }
            if let screen = request.screen {
                return workspaces.display(n, onScreen: screen, source: "cli") { [weak self] message in
                    self?.refresh()
                    reply(message.hasPrefix("no screen") ? .failure(message) : IPCResponse(ok: true, message: message))
                }
            }
            workspaces.switchTo(n, source: "cli") { [weak self] message in
                self?.refresh()
                reply(IPCResponse(ok: true, message: message))
            }
        case .config:
            reply(IPCResponse(ok: true, message: configReport()))
        case .keyboards:
            let lines = remap.map { r in
                ["remap: " + (r.settings.enabled ? "on, preset \(r.settings.preset.rawValue)" : "off")
                    + (r.karabinerRunning ? " (Karabiner-Elements running: keyboards left to it)" : "")] + r.report
            } ?? ["remap: not started"]
            reply(IPCResponse(ok: true, message: lines.joined(separator: "\n")))
        case .focus:
            guard let id = windowID, let window = registry.store.windows[id] else {
                return reply(.failure("unknown window \(windowID.map(\.description) ?? "(none)")"))
            }
            focus.focus(window, source: "cli") { outcome in
                reply(IPCResponse(ok: true, message: outcome.rawValue))
            }
        case .moveToWorkspace:
            guard let n = request.workspace else { return reply(.failure("missing workspace number")) }
            workspaces.move(windowID, to: n, source: "cli") { [weak self] message in
                self?.refresh()
                reply(IPCResponse(ok: true, message: message))
            }
        case .tiling:
            reply(IPCResponse(ok: true, message: tilingCommand(request.args ?? [], windowID: windowID)))
        case .update:
            updateCommand(request.args ?? [], reply: reply)
        case .arrangement:
            let (ok, message) = arrangementCommand(request.args ?? [])
            reply(ok ? IPCResponse(ok: true, message: message) : .failure(message))
        case .zones:
            let (ok, message) = zonesCommand(request.args ?? [])
            reply(ok ? IPCResponse(ok: true, message: message) : .failure(message))
        case .spike:
            // Development tools (screenshots of Pavé's own windows, the update
            // signature check): not in release builds, whose socket answers less.
            #if DEBUG
            switch request.args?.first {
            case "update-signature":
                // pave spike update-signature PATH: would an update to this app be accepted?
                guard let path = request.args?.dropFirst().first else { return reply(.failure("usage: pave spike update-signature PATH.app")) }
                do {
                    try UpdateService.checkSignature(of: URL(fileURLWithPath: path))
                    reply(IPCResponse(ok: true, message: "accepted: signed like this app"))
                } catch {
                    reply(.failure("refused: \(error)"))
                }
            case "shot":
                // pave spike shot settings|about [section] light|dark PATH
                let args = Array(request.args?.dropFirst() ?? [])
                guard args.count >= 3 else { return reply(.failure("usage: pave spike shot settings|about|onboarding [section|page] light|dark PATH")) }
                switch args[0] {
                case "about": windows.showAbout()
                case "onboarding": windows.showOnboarding(page: args.count == 4 ? Int(args[1]) ?? 0 : 0)
                default: windows.showSettings()
                }
                if args.count == 4, let section = SettingsView.Section(rawValue: args[1]) { settingsModel.section = section }
                let dark = args[args.count - 2] == "dark", path = args[args.count - 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    MainActor.assumeIsolated {
                        reply(IPCResponse(ok: true, message: self?.windows.snapshot(args[0], dark: dark, to: path) ?? "?"))
                    }
                }
            default:
                reply(.failure("usage: pave spike shot settings|about|onboarding … | update-signature PATH"))
            }
            #else
            reply(.failure("pave spike: development builds only"))
            #endif
        }
    }

    /// `pave tiling …`.
    func tilingCommand(_ args: [String], windowID: WindowID?) -> String {
        let n = workspaces.state.active
        func setTiled(_ on: Bool) -> String {
            var list = config.config.tilingWorkspaces
            if on { list.insert(n) } else { list.remove(n) }
            setConfig("workspaces", "tiling", to: "[" + list.sorted().map(String.init).joined(separator: ", ") + "]")
            return "workspace \(n): \(on ? "tiled" : "floating")"
        }
        switch TilingCommand.parse(args) {
        case .failure(let usage): return usage.description
        case .success(.on): return setTiled(true)
        case .success(.off): return setTiled(false)
        case .success(.toggle): return setTiled(!config.config.tilingWorkspaces.contains(n))
        case .success(.float): return tiling.toggleFloating(windowID: windowID, source: "cli")
        case .success(.orientation):
            tiling.toggleOrientation(source: "cli")
            return "orientation toggled"
        case .success(.focus(let d)):
            tiling.focus(d, source: "cli")
            return "focus \(d.rawValue)"
        case .success(.resize(let d)):
            tiling.resize(d, source: "cli")
            return "resize \(d.rawValue)"
        case .success(.move(let d)):
            let command: LayoutCommand = [.left: .snapLeft, .right: .snapRight, .up: .maximize, .down: .restore][d]!
            guard tiling.handles(command, windowID: windowID) else { return "window not tiled" }
            tiling.perform(command, windowID: windowID, source: "cli")
            return "move \(d.rawValue)"
        }
    }
}
