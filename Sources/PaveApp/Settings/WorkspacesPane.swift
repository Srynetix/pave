import AppKit
import PaveCore
import SwiftUI

struct WorkspacesPane: View {
    @ObservedObject var model: SettingsModel
    var goToKeyboard: () -> Void
    @State private var gaps: Double = 8

    var body: some View {
        let c = model.config
        Form {
            SwiftUI.Section {
                Toggle(isOn: Binding(get: { c.workspacesEnabled }, set: { model.set("workspaces", "enabled", $0) })) {
                    Text("Virtual workspaces")
                    Text("\(model.mainKey)1…9 shows a workspace on its screen, \(model.mainKey)⇧1…9 sends the active window there.")
                }
                Picker("The \(model.mainKey)Tab switcher shows", selection: Binding(
                    get: { c.switcherScope }, set: { model.set("switcher", "scope", string: $0.rawValue) })
                ) {
                    Text("The visible workspace").tag(PaveConfig.SwitcherScope.workspace)
                    Text("This screen").tag(PaveConfig.SwitcherScope.screen)
                    Text("All workspaces").tag(PaveConfig.SwitcherScope.all)
                }
                .pickerStyle(.segmented)
            }
            SwiftUI.Section {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text(verbatim: "")
                        Text("Name (shown when hovering its number)")
                        Text("Icon")
                        Text("Screen")
                        Text("Tiling")
                        Text("Windows").gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.workspaces) { row in
                        WorkspaceRowView(model: model, row: row, tiled: c.tilingWorkspaces.contains(row.id))
                    }
                }
                .disabled(!c.workspacesEnabled)
            } header: {
                Text("Workspaces")
            } footer: {
                Text("Choosing a screen shows the workspace there, and it stays attached to it. The icon replaces the number in the taskbar: an emoji, up to 2 letters, or sf: and an SF Symbol name (sf:globe). Names and icons never go to the logs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Tiling") {
                LabeledContent("Gap between tiles") {
                    HStack {
                        Slider(value: $gaps, in: 0...24) { editing in
                            if !editing { model.setGaps(Int(gaps.rounded())) }
                        }
                        .frame(width: 180)
                        Text("\(Int(gaps.rounded())) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent {
                    Button("Edit…", action: goToKeyboard)
                } label: {
                    Text("Shortcuts")
                    Text("\(model.mainKey) + arrows move · \(model.mainKey)⌥ + arrows focus · \(model.mainKey)⌥⇧ + arrows resize · \(model.mainKey)⇧Space floating")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { gaps = Double(c.tilingGaps) }
        .onChange(of: c.tilingGaps) { _, new in gaps = Double(new) }
    }
}

private struct WorkspaceRowView: View {
    @ObservedObject var model: SettingsModel
    var row: SettingsModel.WorkspaceRow
    var tiled: Bool
    @State private var name = ""
    @FocusState private var editing: Bool
    @State private var icon = ""
    @FocusState private var editingIcon: Bool

    private var iconValid: Bool { WorkspaceIcon.isValid(icon) }

    /// The badge as the taskbar draws it: the icon being typed, else the number.
    @ViewBuilder private var badge: some View {
        switch WorkspaceIcon(icon) {
        case .symbol(let name)? where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil:
            Image(systemName: name).font(.callout.weight(.semibold))
        case .text(let text)?:
            Text(verbatim: text).font(.callout.weight(.semibold)).minimumScaleFactor(0.5)
        default:
            Text(verbatim: "\(row.id)").font(.callout.weight(.semibold))
        }
    }

    var body: some View {
        GridRow {
            badge
                .lineLimit(1)
                .frame(width: 22, height: 22)
                .background(row.visible ? Color.accentColor : Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(row.visible ? Color.white : Color.primary)
                .accessibilityLabel(row.visible ? String(localized: "Workspace \(row.id), shown") : String(localized: "Workspace \(row.id)"))
            TextField("Name of workspace \(row.id)", text: $name, prompt: Text("Optional"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .onSubmit { model.setName(row.id, name) }
                .onChange(of: editing) { _, now in if !now { model.setName(row.id, name) } }
            TextField("Icon of workspace \(row.id)", text: $icon, prompt: Text(verbatim: "\(row.id)"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .focused($editingIcon)
                .foregroundStyle(iconValid ? Color.primary : Color.red)
                .help(iconValid ? "" : String(localized: "An emoji, up to 2 letters, or sf: and an SF Symbol name"))
                .onSubmit { model.setIcon(row.id, icon) }
                .onChange(of: editingIcon) { _, now in if !now { model.setIcon(row.id, icon) } }
            Picker("Screen of workspace \(row.id)", selection: Binding(
                get: { row.screen ?? -1 },
                set: { if $0 >= 0 { model.displayWorkspace(row.id, $0) } })
            ) {
                if row.screen == nil { Text("When first shown").tag(-1) }
                ForEach(model.screens) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 180)
            Toggle("Tiling of workspace \(row.id)", isOn: Binding(get: { tiled }, set: { model.setTiled(row.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Text(row.windows == 0 ? String(localized: "empty") : "\(row.windows)")
                .foregroundStyle(row.windows == 0 ? .secondary : .primary)
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
        .onAppear { name = row.name; icon = row.icon }
        .onChange(of: row.name) { _, new in if !editing { name = new } }
        .onChange(of: row.icon) { _, new in if !editingIcon { icon = new } }
    }
}
