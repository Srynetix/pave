import Combine
import PaveCore
import SwiftUI

/// The welcome guide, shown once at first launch (and from Settings ›
/// General): permissions, keyboard preset, what to turn on. Every choice
/// goes through the config file, like the Settings window.
struct OnboardingView: View {
    @ObservedObject var model: SettingsModel
    var finish: () -> Void
    @State private var page: Int

    init(model: SettingsModel, finish: @escaping () -> Void, initialPage: Int = 0) {
        self.model = model
        self.finish = finish
        _page = State(initialValue: initialPage)
    }
    private let pages = 5
    /// Permissions change in System Settings: look again while the guide is open.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: permissions
                case 2: keyboard
                case 3: features
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(32)
            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(
                            width: 7, height: 7)
                    }
                }
                .accessibilityLabel("Step \(page + 1) of \(pages)")
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                if page < pages - 1 {
                    Button("Continue") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(page == 1 && !model.status.trusted)
                } else {
                    Button("Start using Pavé", action: finish).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
        }
        .frame(width: 640, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(tick) { _ in model.requestRefresh() }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            Text("Welcome to Pavé").font(.largeTitle.weight(.semibold))
            Text("The switcher, snapping, taskbar and workspaces you know from Windows and Linux, on your Mac.")
                .font(.title3).foregroundStyle(.secondary)
            Text(
                "A few steps: the permissions Pavé needs, your keyboard, and what to turn on. Everything can be changed later in Settings, or in the config file."
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissions: some View {
        let status = model.status
        return VStack(alignment: .leading, spacing: 18) {
            Text("Permissions").font(.title.weight(.semibold))
            PermissionRow(
                granted: status.trusted, title: String(localized: "Accessibility"),
                detail: String(localized: "Required: it lets Pavé move and resize windows, and read your shortcuts."),
                action: { model.perform(.accessibility) })
            PermissionRow(
                granted: status.screenRecording, title: String(localized: "Screen Recording"),
                detail: String(
                    localized:
                        "Optional: live previews in the switcher and the taskbar. Without it, Pavé shows app icons."),
                action: { model.perform(.screenRecording) })
            Text(
                "Window titles and workspace names never reach the logs, previews stay in memory, and nothing leaves your Mac."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !status.trusted {
                Text("Continue once Accessibility is granted (macOS may ask to quit and reopen Pavé).")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var keyboard: some View {
        let c = model.config
        return VStack(alignment: .leading, spacing: 18) {
            Text("Your keyboard").font(.title.weight(.semibold))
            Picker(
                "Keyboard",
                selection: Binding(
                    get: { c.keyboardRemap && c.keyboardPreset == .pc ? 0 : 1 },
                    set: { pc in
                        model.set("keyboard", "remap", pc == 0)
                        if pc == 0 { model.set("keyboard", "preset", string: KeyRemap.Preset.pc.rawValue) }
                    })
            ) {
                VStack(alignment: .leading) {
                    Text("PC habits (recommended)")
                    Text(
                        "The key next to the space bar drives Pavé (⌘Tab, ⌘ + arrows, like Alt+Tab and Win + arrows); the bottom-left key does copy and paste (Ctrl+C, Ctrl+V); right ⌘ is Alt Gr."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .tag(0)
                VStack(alignment: .leading) {
                    Text("Mac keys")
                    Text("Your keys stay as they are; Pavé's shortcuts use ⌃ (⌃Tab, ⌃ + arrows).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .tag(1)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Pavé remaps each keyboard as it is plugged in, and steps aside when Karabiner-Elements runs.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var features: some View {
        let c = model.config
        let login = model.status.login
        return VStack(alignment: .leading, spacing: 14) {
            Text("What to turn on").font(.title.weight(.semibold))
            Text("Snapping and the switcher are always on. The rest is yours to choose.").foregroundStyle(.secondary)
            SwitchRow(
                title: String(localized: "Taskbar"),
                detail: String(
                    localized: "One entry per window on every screen, previews, pinned apps, a Start button."),
                isOn: Binding(get: { c.taskbarEnabled }, set: { model.set("taskbar", "enabled", $0) }))
            SwitchRow(
                title: String(localized: "Hide the Dock while the taskbar is on"),
                detail: String(localized: "Put back exactly as it was when you turn it off."),
                isOn: Binding(get: { c.taskbarHideDock }, set: { model.set("taskbar", "hide-dock", $0) })
            )
            .disabled(!c.taskbarEnabled)
            .padding(.leading, 20)
            SwitchRow(
                title: String(localized: "Virtual workspaces"),
                detail: String(
                    localized:
                        "\(model.mainKey)1…9 shows a workspace on its screen, \(model.mainKey)⇧1…9 sends the window there."
                ),
                isOn: Binding(get: { c.workspacesEnabled }, set: { model.set("workspaces", "enabled", $0) }))
            SwitchRow(
                title: String(localized: "Zones"),
                detail: String(
                    localized:
                        "Layouts for wide screens: drag a window into a zone, \(model.mainKey)⇧Z picks the layout."),
                isOn: Binding(get: { c.zones.enabled }, set: { model.set("zones", "enabled", $0) }))
            SwitchRow(
                title: String(localized: "Launch Pavé at login"),
                detail: login == .devCopy ? String(localized: "Only for the copy in Applications.") : nil,
                isOn: Binding(get: { login == .on || login == .needsApproval }, set: { model.setLogin($0) })
            )
            .disabled(login == .devCopy)
        }
    }

    private var ready: some View {
        let k = model.mainKey
        return VStack(alignment: .leading, spacing: 14) {
            Text("You're all set").font(.title.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                ShortcutRow(
                    keys: "\(k)Tab", text: String(localized: "Switch windows (type to search, W closes, Q quits)"))
                ShortcutRow(keys: "\(k)← →", text: String(localized: "Halves, or zones on a screen with a layout"))
                ShortcutRow(keys: "\(k)↑ ↓", text: String(localized: "Maximize, quarters, back to the previous size"))
                ShortcutRow(keys: "\(k)⇧← →", text: String(localized: "Send the window to the next screen"))
                if model.config.workspacesEnabled {
                    ShortcutRow(keys: "\(k)1…9", text: String(localized: "Show a workspace"))
                }
                if model.config.zones.enabled {
                    ShortcutRow(keys: "\(k)⇧Z", text: String(localized: "Pick the zone layout of the screen"))
                }
                ShortcutRow(keys: "\(k)⇧A", text: String(localized: "Save or restore a window arrangement"))
            }
            Text(
                "Drag a window to an edge to snap it, hold ⌥ to move it freely. Pavé lives in the menu bar: Settings, logs and help are there."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A setting with its explanation on the left, its switch on the right edge.
private struct SwitchRow: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}

private struct PermissionRow: View {
    var granted: Bool
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .accessibilityLabel(granted ? String(localized: "Granted") : String(localized: "Not granted"))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }
}

private struct ShortcutRow: View {
    var keys: String
    var text: String

    var body: some View {
        GridRow {
            Text(verbatim: keys)
                .font(.body.monospaced().weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            Text(text)
        }
    }
}
