// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import PaveCore
import SwiftUI

struct AppsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let rules = model.config.appRules.keys.sorted {
            model.appName($0).localizedCaseInsensitiveCompare(model.appName($1)) == .orderedAscending
        }
        ScrollViewReader { scroll in
            Form {
                SwiftUI.Section {
                    if rules.isEmpty {
                        Text("No rules: every app follows the general settings.").foregroundStyle(.secondary)
                    }
                    ForEach(rules, id: \.self) { id in RuleRow(model: model, bundleID: id).id(id) }
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
            .onAppear { scrollToFocused(scroll) }
            .onChange(of: model.focusedRule) { scrollToFocused(scroll) }
        }
    }

    /// The taskbar asked for this app's rule: shown, once.
    private func scrollToFocused(_ scroll: ScrollViewProxy) {
        guard let id = model.focusedRule else { return }
        DispatchQueue.main.async {
            withAnimation { scroll.scrollTo(id, anchor: .top) }
            model.focusedRule = nil
        }
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
            TitleRules(model: model, bundleID: bundleID)
        }
        .padding(.vertical, 4)
    }
}

/// `[apps."…".titles]`: the workspace of new windows by title pattern, or all.
private struct TitleRules: View {
    @ObservedObject var model: SettingsModel
    var bundleID: String

    var body: some View {
        let rule = model.rule(bundleID)
        let open = model.windowTitles(bundleID)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rule.titles.keys.sorted(), id: \.self) { pattern in
                TitleRuleRow(
                    model: model, bundleID: bundleID, pattern: pattern, target: rule.titles[pattern] ?? 1,
                    matches: open.filter { TitlePattern.matches(pattern, $0.title) }.count)
            }
            HStack {
                Menu("Add a title rule") {
                    let suggestions = Array(Set(open.map(\.title))).sorted().filter { rule.titles["*\($0)"] == nil }
                    if !suggestions.isEmpty {
                        SwiftUI.Section("From an open window") {
                            ForEach(suggestions, id: \.self) { title in
                                Button(title) {
                                    let n = open.first { $0.title == title }?.workspace ?? rule.workspace ?? 1
                                    model.setTitleRule(bundleID, "*\(title)", .workspace(n))
                                }
                            }
                        }
                    }
                    Button("Empty pattern") {
                        var pattern = "*"
                        while rule.titles[pattern] != nil { pattern += "*" }
                        model.setTitleRule(bundleID, pattern, .workspace(rule.workspace ?? 1))
                    }
                }
                .fixedSize()
                Spacer()
            }
            Text(
                "New windows whose title matches a pattern open on its workspace, or on all of them: * is any text, ? one character, case ignored. *Work: titles ending with Work. The longest pattern wins, before the workspace above."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct TitleRuleRow: View {
    @ObservedObject var model: SettingsModel
    var bundleID: String
    var pattern: String
    var target: TitleTarget
    var matches: Int
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField("Title pattern", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { commit() }
                .onAppear { text = pattern }
                .onChange(of: pattern) { text = pattern }
            Picker(
                "Workspace",
                selection: Binding(get: { target }, set: { model.setTitleRule(bundleID, pattern, $0) })
            ) {
                ForEach(Workspaces.range.map { $0 }, id: \.self) {
                    Text(verbatim: "\($0)").tag(TitleTarget.workspace($0))
                }
                Text("All").tag(TitleTarget.everywhere)
            }
            .labelsHidden()
            .frame(width: 70)
            Text(matches == 0 ? String(localized: "no open window") : String(localized: "\(matches) open window(s)"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Button {
                model.setTitleRule(bundleID, pattern, nil)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete this title rule")
        }
    }

    /// Return: the pattern is renamed (an empty one or a duplicate is refused).
    private func commit() {
        if text.isEmpty || model.rule(bundleID).titles[text] != nil && text != pattern {
            text = pattern
        } else {
            model.renameTitleRule(bundleID, from: pattern, to: text)
        }
    }
}
