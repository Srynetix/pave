import AppKit
import PaveCore
import SwiftUI

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let status = model.status
        Form {
            if let error = status.configError {
                SwiftUI.Section {
                    Banner(
                        text: String(
                            localized:
                                "The configuration could not be read: \(error). The previous settings stay active."),
                        action: (String(localized: "Open the file"), { model.perform(.openConfig) })
                    )
                    .padding(-20)
                    .listRowInsets(EdgeInsets())
                }
            }
            SwiftUI.Section {
                Toggle(
                    isOn: Binding(
                        get: { status.login == .on || status.login == .needsApproval }, set: { model.setLogin($0) })
                ) {
                    Text("Launch Pavé at login")
                    switch status.login {
                    case .devCopy: Text("Only for the installed copy (just install).")
                    case .needsApproval: Text("To approve in System Settings > General > Login Items.")
                    default: EmptyView()
                    }
                }
                .disabled(status.login == .devCopy)
                LabeledContent {
                    if let version = status.updateAvailable {
                        Button("Install \(version)…") { model.perform(.checkUpdates) }.disabled(status.updateBusy)
                    } else {
                        Button("Check Now") { model.perform(.checkUpdates) }.disabled(
                            status.updateBusy || !status.canUpdate)
                    }
                } label: {
                    Text("Updates")
                    Text(verbatim: "\(model.version) · \(status.update)")
                }
                Toggle(isOn: Binding(get: { model.config.updatesCheck }, set: { model.set("updates", "check", $0) })) {
                    Text("Check for updates automatically")
                    Text("At launch and once a day. Nothing is installed without asking.")
                }
                LabeledContent {
                    Button("Show…") { model.perform(.onboarding) }
                } label: {
                    Text("Welcome guide")
                    Text("Permissions, keyboard and features, step by step.")
                }
                LabeledContent {
                    HStack {
                        Picker("Language", selection: Binding(get: { model.language }, set: model.setLanguage)) {
                            Text("Same as macOS").tag(SettingsModel.Language.system)
                            Text(verbatim: "English").tag(SettingsModel.Language.english)
                            Text(verbatim: "Français").tag(SettingsModel.Language.french)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if model.languageNeedsRestart { Button("Restart Pavé", action: model.restart) }
                    }
                } label: {
                    Text("Language")
                    if model.languageNeedsRestart { Text("Applies when Pavé restarts.") }
                }
            }
            SwiftUI.Section("Status") {
                LabeledContent("Accessibility") {
                    if status.trusted {
                        StatusDot(ok: true, text: String(localized: "Granted"))
                    } else {
                        Button("Grant…") { model.perform(.accessibility) }
                    }
                }
                LabeledContent("Tracked windows") {
                    Text(
                        status.hung.isEmpty
                            ? String(localized: "\(status.windows) windows in \(status.apps) apps")
                            : String(
                                localized:
                                    "\(status.windows) windows in \(status.apps) apps · not responding: \(status.hung.joined(separator: ", "))"
                            ))
                }
                LabeledContent("Screens", value: status.screens.joined(separator: " · "))
                LabeledContent("Keyboard", value: status.keyboard)
            }
            SwiftUI.Section("Conflicting macOS settings") {
                LabeledContent {
                    HStack {
                        StatusDot(
                            ok: !status.nativeTiling,
                            text: status.nativeTiling ? String(localized: "On") : String(localized: "Off"))
                        Button(
                            status.nativeTiling ? String(localized: "Turn Off") : String(localized: "Turn On"),
                            action: model.toggleNativeTiling)
                    }
                } label: {
                    Text("macOS window tiling")
                    Text("It snaps windows to the edges along with Pavé.")
                }
                LabeledContent {
                    HStack {
                        StatusDot(
                            ok: !status.stageManager,
                            text: status.stageManager ? String(localized: "On") : String(localized: "Off"))
                        if status.stageManager { Button("Settings…") { model.perform(.stageManager) } }
                    }
                } label: {
                    Text("Stage Manager")
                    Text("It moves windows on its own, against workspaces and tiling.")
                }
            }
            SwiftUI.Section("Configuration and troubleshooting") {
                LabeledContent {
                    HStack {
                        Button("Open") { model.perform(.openConfig) }
                        Button("Show in Finder") { model.perform(.revealConfig) }
                    }
                } label: {
                    Text("Configuration file")
                    Text(verbatim: "\(status.configPath) · \(status.configState)")
                }
                LabeledContent {
                    HStack {
                        Button("Logs") { model.perform(.showLogs) }
                        Button("Reapply the remap") { model.perform(.reapplyRemap) }
                        Button("Bring back all windows") { model.perform(.restoreAll) }
                    }
                } label: {
                    Text("Troubleshooting")
                    Text("Logs hold neither window titles nor workspace names.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
