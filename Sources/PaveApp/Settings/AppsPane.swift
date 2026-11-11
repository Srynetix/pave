import AppKit
import PaveCore
import SwiftUI

struct AppsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let rules = model.config.appRules.keys.sorted {
            model.appName($0).localizedCaseInsensitiveCompare(model.appName($1)) == .orderedAscending
        }
        Form {
            SwiftUI.Section {
                if rules.isEmpty {
                    Text("No rules: every app follows the general settings.").foregroundStyle(.secondary)
                }
                ForEach(rules, id: \.self) { id in RuleRow(model: model, bundleID: id) }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Menu("Add a rule") {
                        ForEach(model.runningApps.filter { model.config.appRules[$0.bundleID] == nil }) { app in
                            Button(app.name) { model.addRule(app.bundleID) }
                        }
                    }
                    .fixedSize()
                }
            } footer: {
                Text("Dialogs, sheets and panels (Open, Save, Settings) are never placed, whatever the rule.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RuleRow: View {
    @ObservedObject var model: SettingsModel
    var bundleID: String

    var body: some View {
        let rule = model.rule(bundleID)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: model.appIcon(bundleID)).resizable().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.appName(bundleID))
                    Text(bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.deleteRule(bundleID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete the rule of \(model.appName(bundleID))")
            }
            HStack(spacing: 14) {
                Picker(
                    "Workspace",
                    selection: Binding(
                        get: { rule.workspace ?? 0 },
                        set: { model.setRule(bundleID, "workspace", $0 == 0 ? nil : "\($0)") })
                ) {
                    Text("Visible screen").tag(0)
                    ForEach(Workspaces.range.map { $0 }, id: \.self) { Text("Always \($0)").tag($0) }
                }
                .frame(width: 210)
                Picker(
                    "Zone",
                    selection: Binding(
                        get: { rule.zone ?? 0 },
                        set: { model.setRule(bundleID, "zone", $0 == 0 ? nil : "\($0)") })
                ) {
                    Text("Where it opens").tag(0)
                    ForEach(1...9, id: \.self) { Text("Zone \($0)").tag($0) }
                }
                .frame(width: 190)
                .help(String(localized: "On a screen that has a zone layout, its new windows open in this zone."))
                Toggle(
                    "Tiled",
                    isOn: Binding(get: { rule.tile }, set: { model.setRule(bundleID, "tile", $0 ? nil : "false") }))
                Toggle(
                    "Drag snap",
                    isOn: Binding(
                        get: { rule.dragSnap }, set: { model.setRule(bundleID, "drag-snap", $0 ? nil : "false") }))
                Toggle(
                    "Covers the taskbar",
                    isOn: Binding(
                        get: { rule.taskbarOverlap },
                        set: { model.setRule(bundleID, "taskbar-overlap", $0 ? "\"allow\"" : nil) }))
                Toggle(
                    "Ignored",
                    isOn: Binding(get: { rule.ignore }, set: { model.setRule(bundleID, "ignore", $0 ? "true" : nil) }))
            }
            .toggleStyle(.checkbox)
            .disabled(false)
        }
        .padding(.vertical, 4)
    }
}
