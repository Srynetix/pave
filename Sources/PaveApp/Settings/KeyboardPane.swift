// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore
import SwiftUI

struct KeyboardPane: View {
    @ObservedObject var model: SettingsModel

    private static let windowActions: [HotkeyAction] =
        LayoutCommand.allCases.map { .layout($0) } + [.switcher, .switcherSameApp, .zonePicker, .arrangementPicker]
    private static let tilingActions: [HotkeyAction] =
        Direction.allCases.map { .focus($0) } + Direction.allCases.map { .resize($0) } + [.toggleFloating]

    var body: some View {
        let c = model.config
        Form {
            SwiftUI.Section {
                Toggle(isOn: Binding(get: { c.keyboardRemap }, set: { model.set("keyboard", "remap", $0) })) {
                    Text("Keyboard remap")
                    Text(
                        "PC preset: the key next to the space bar (Win on a PC keyboard) runs Pavé's shortcuts, the bottom-left key does copy and paste, right ⌘ is Alt Gr. Turn it off if you keep Karabiner."
                    )
                }
                Picker(
                    "Preset",
                    selection: Binding(
                        get: { c.keyboardPreset }, set: { model.set("keyboard", "preset", string: $0.rawValue) })
                ) {
                    Text(verbatim: "PC").tag(KeyRemap.Preset.pc)
                    Text("None").tag(KeyRemap.Preset.none)
                }
                .pickerStyle(.segmented)
                .disabled(!c.keyboardRemap)
                ForEach(model.keyboards) { keyboard in
                    LabeledContent {
                        Toggle(
                            "Leave alone",
                            isOn: Binding(
                                get: { c.keyboardSkip.contains(keyboard.id) },
                                set: { model.setSkipped(keyboard.id, $0) })
                        )
                        .toggleStyle(.checkbox)
                    } label: {
                        Text(keyboard.name)
                        Text(keyboard.state)
                    }
                }
            }
            if let conflict = model.conflict {
                SwiftUI.Section {
                    Banner(
                        text: String(
                            localized: "\(model.label(conflict.hotkey)) is already used by “\(conflict.other.label)”."),
                        action: (String(localized: "Replace"), { model.replaceConflict() }),
                        dismiss: { model.conflict = nil }
                    )
                    .padding(-20)
                    .listRowInsets(EdgeInsets())
                }
            }
            SwiftUI.Section("Windows") {
                ForEach(Self.windowActions, id: \.configName) { ShortcutRow(model: model, action: $0) }
            }
            SwiftUI.Section("Workspaces and tiling") {
                DisclosureGroup("Show a workspace (\(model.mainKey)1…9)") {
                    ForEach(Workspaces.range.map { HotkeyAction.workspace($0) }, id: \.configName) {
                        ShortcutRow(model: model, action: $0)
                    }
                }
                DisclosureGroup("Send the window (\(model.mainKey)⇧1…9)") {
                    ForEach(Workspaces.range.map { HotkeyAction.moveToWorkspace($0) }, id: \.configName) {
                        ShortcutRow(model: model, action: $0)
                    }
                }
                ForEach(Self.tilingActions, id: \.configName) { ShortcutRow(model: model, action: $0) }
            }
            SwiftUI.Section {
                VStack(alignment: .leading, spacing: 6) {
                    if model.status.pcKeys {
                        Text(
                            "Shortcuts are shown as the keys you press. With the PC preset, ⌘ (next to the space bar) is what macOS receives as ⌃: the configuration file writes it \"ctrl\"."
                        )
                    }
                    Text(
                        "Click a shortcut, then type the new one. Escape cancels, ⌫ removes it. Pavé's shortcuts are paused while you type."
                    )
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.stopRecording() }
    }
}

private struct ShortcutRow: View {
    @ObservedObject var model: SettingsModel
    var action: HotkeyAction

    var body: some View {
        let recording = model.recording == action
        LabeledContent(action.label) {
            Button {
                if recording { model.stopRecording() } else { model.startRecording(action) }
            } label: {
                Text(
                    recording
                        ? String(localized: "Type the shortcut…")
                        : model.hotkey(action).map(model.label) ?? String(localized: "None")
                )
                .frame(minWidth: 110)
                .foregroundStyle(recording ? Color.accentColor : (model.hotkey(action) == nil ? .secondary : .primary))
            }
            .accessibilityLabel(
                "\(action.label): " + (model.hotkey(action).map(model.label) ?? String(localized: "no shortcut")))
        }
    }
}
