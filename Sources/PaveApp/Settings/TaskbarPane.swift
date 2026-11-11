// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore
import SwiftUI

struct TaskbarPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let c = model.config
        Form {
            SwiftUI.Section {
                Toggle(isOn: Binding(get: { c.taskbarEnabled }, set: { model.set("taskbar", "enabled", $0) })) {
                    Text("Taskbar")
                    Text("At the bottom of each screen, with the windows of the workspace shown.")
                }
                Toggle(isOn: Binding(get: { c.taskbarHideDock }, set: { model.set("taskbar", "hide-dock", $0) })) {
                    Text("Hide the Dock")
                    Text("Its settings come back when you turn the taskbar off or quit Pavé.")
                }
                .disabled(!c.taskbarEnabled)
                Picker(
                    "Group the windows of an app",
                    selection: Binding(
                        get: { c.taskbarGrouping }, set: { model.set("taskbar", "grouping", string: $0.rawValue) })
                ) {
                    Text("Never (one entry per window)").tag(TaskbarGrouping.never)
                    Text("Always (one entry per app)").tag(TaskbarGrouping.always)
                    Text("When the taskbar is full").tag(TaskbarGrouping.whenFull)
                }
                Toggle(
                    isOn: Binding(
                        get: { c.taskbarOptionOpensLauncher },
                        set: { model.set("taskbar", "start-key", string: $0 ? "option" : "none") })
                ) {
                    Text("⌥ alone opens the launcher")
                    Text("Like the Windows key.")
                }
            }
            SwiftUI.Section {
                List {
                    ForEach(c.taskbarPinned, id: \.self) { id in
                        HStack(spacing: 10) {
                            Image(nsImage: model.appIcon(id)).resizable().frame(width: 22, height: 22)
                            Text(model.appName(id))
                            Spacer()
                            Button {
                                model.setPinned(c.taskbarPinned.filter { $0 != id })
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(model.appName(id))")
                        }
                    }
                    .onMove { from, to in
                        var list = c.taskbarPinned
                        list.move(fromOffsets: from, toOffset: to)
                        model.setPinned(list)
                    }
                }
                HStack {
                    Text("Drag to reorder.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Add an app") {
                        ForEach(model.runningApps.filter { !c.taskbarPinned.contains($0.bundleID) }) { app in
                            Button(app.name) { model.setPinned(c.taskbarPinned + [app.bundleID]) }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Pinned apps")
            }
        }
        .formStyle(.grouped)
    }
}
