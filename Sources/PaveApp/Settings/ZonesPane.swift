import AppKit
import PaveCore
import SwiftUI

struct ZonesPane: View {
    @ObservedObject var model: SettingsModel
    @State private var gaps: Double = 8

    var body: some View {
        let z = model.config.zones
        let choices = z.choices
        Form {
            SwiftUI.Section {
                Toggle(isOn: Binding(get: { z.enabled }, set: { model.set("zones", "enabled", $0) })) {
                    Text("Zones")
                    Text("On a screen with a layout, a dragged window goes into the zone under the pointer (⇧ spans several, ⌥ moves freely), and \(model.mainKey)← → move between zones. \(model.mainKey)⇧Z picks the layout.")
                }
                Picker("Show the zones while dragging", selection: Binding(
                    get: { z.show }, set: { model.set("zones", "show", string: $0.rawValue) })
                ) {
                    Text("Always").tag(ZoneSettings.Show.always)
                    Text("Only with \(model.mainKey) held").tag(ZoneSettings.Show.ctrl)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: Binding(get: { z.keyboard }, set: { model.set("zones", "keyboard", $0) })) {
                    Text("Arrows move between zones")
                    Text("Off: \(model.mainKey)← → keep halves and quarters on every screen.")
                }
                LabeledContent("Gaps") {
                    HStack {
                        Slider(value: $gaps, in: 0...32) { editing in
                            if !editing, Int(gaps.rounded()) != z.gaps {
                                model.setValueAndApply("zones", "gaps", "\(Int(gaps.rounded()))")
                            }
                        }
                        .frame(width: 180)
                        Text("\(Int(gaps.rounded())) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            SwiftUI.Section("Moving and resizing") {
                Toggle(isOn: Binding(
                    get: { model.config.windowMagnet > 0 },
                    set: { model.setValueAndApply("windows", "magnet", $0 ? "12" : "0") })
                ) {
                    Text("Magnetic windows")
                    Text("A window dropped near another one or the screen's edge sticks to it. ⌥ while dragging: no magnet.")
                }
                Toggle(isOn: Binding(get: { model.config.magnetFill }, set: { model.set("windows", "magnet-fill", $0) })) {
                    Text("Fill the free space")
                    Text("Stuck against another window, it also takes the free space there: next to a window on the right two thirds, it fills the first third.")
                }
                .disabled(model.config.windowMagnet == 0)
                Toggle(isOn: Binding(get: { model.config.resizeNeighbours }, set: { model.set("windows", "resize-neighbours", $0) })) {
                    Text("Resize the neighbours too")
                    Text("Resizing a window by an edge another window touches moves that window's edge along.")
                }
            }
            SwiftUI.Section {
                ForEach(model.zoneScreens) { row in
                    LabeledContent {
                        HStack {
                            Picker("Layout of \(row.name)", selection: Binding(
                                get: { row.layout }, set: { model.assignZoneLayout(row.id, $0) })
                            ) {
                                ForEach(choices, id: \.self) { Text(Self.title(of: $0)).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                            Button("Edit…") { model.editZones(row.id, row.layout == ZoneSettings.none ? nil : row.layout) }
                        }
                    } label: {
                        Text(row.name)
                        Text("[zones.screens] \(row.key)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Screens")
            } footer: {
                Text("Windows already in zones follow a new layout. A screen is found by its UUID, \"builtin\", or part of its name, so the layout survives a re-plug.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!z.enabled)
            SwiftUI.Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                    ForEach(1...9, id: \.self) { n in
                        HStack(spacing: 8) {
                            Text(verbatim: "\(n)")
                                .font(.callout.weight(.semibold))
                                .frame(width: 22, height: 22)
                                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                            Picker("Layout of workspace \(n)", selection: Binding(
                                get: { z.workspaces[n] ?? "" }, set: { model.setWorkspaceZones(n, $0.isEmpty ? nil : $0) })
                            ) {
                                Text("Screen's").tag("")
                                ForEach(choices, id: \.self) { Text(Self.title(of: $0)).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            } header: {
                Text("Workspace overrides")
            } footer: {
                Text("Only on screens that have a layout. Tiled workspaces ignore zones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!z.enabled || !model.config.workspacesEnabled)
            SwiftUI.Section {
                ForEach(ZoneLayout.builtIn.map(\.name) + z.layouts.keys.filter { name in !ZoneLayout.builtIn.contains { $0.name == name } }.sorted(), id: \.self) { name in
                    let layout = z.layout(named: name)!
                    let mine = z.layouts[name] != nil
                    HStack(spacing: 12) {
                        ZoneMiniature(layout: layout).frame(width: 64, height: 27)
                        VStack(alignment: .leading) {
                            Text(name)
                            Text(mine ? "\(layout.zones.count) zones" : "\(layout.zones.count) zones · built-in")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(mine ? "Edit…" : "Copy and edit…") { model.editZones(nil, name) }
                        if mine {
                            Button(role: .destructive) { model.deleteZoneLayout(name) } label: { Image(systemName: "trash") }
                                .disabled(model.isZoneLayoutUsed(name))
                                .help(model.isZoneLayoutUsed(name) ? String(localized: "Used by a screen or a workspace") : String(localized: "Delete"))
                                .accessibilityLabel("Delete \(name)")
                        }
                    }
                }
                Button("New layout…") { model.editZones(nil, nil) }
            } header: {
                Text("Layouts")
            } footer: {
                Text("The editor opens full screen on the screen under the pointer. Layouts are saved as [layouts.\"<name>\"] in the config file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { gaps = Double(z.gaps) }
        .onChange(of: z.gaps) { _, new in gaps = Double(new) }
    }

    static func title(of name: String) -> String {
        name == ZoneSettings.none ? String(localized: "None (halves)") : name
    }
}

private struct ZoneMiniature: View {
    var layout: ZoneLayout

    var body: some View {
        Canvas { context, size in
            let area = Rect(x: 0, y: 0, width: size.width, height: size.height)
            for f in layout.frames(in: area, gaps: 1.5) {
                let rect = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.accentColor.opacity(0.35)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(.accentColor), lineWidth: 0.8)
            }
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}
