import AppKit
import PaveCore
import SwiftUI

/// The Settings window: a sidebar and five sections. Follows the system
/// appearance (light or dark) like any native window.
///
/// Localization: literals given to SwiftUI views are localized keys; strings
/// built in code go through `String(localized:)`. Translations live in
/// `Resources/Localizable.xcstrings` (English is the source language).
struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general, workspaces, zones, taskbar, keyboard, apps
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .workspaces: String(localized: "Workspaces and tiling")
            case .zones: String(localized: "Zones")
            case .taskbar: String(localized: "Taskbar")
            case .keyboard: String(localized: "Keyboard and shortcuts")
            case .apps: String(localized: "App rules")
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .workspaces: "square.grid.2x2"
            case .zones: "rectangle.split.3x1"
            case .taskbar: "dock.rectangle"
            case .keyboard: "keyboard"
            case .apps: "app.badge"
            }
        }
    }

    @ObservedObject var model: SettingsModel
    var showAbout: () -> Void

    private var section: Binding<Section?> {
        Binding(get: { model.section }, set: { if let new = $0 { model.section = new } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: section) {
                ForEach(Section.allCases) { s in
                    Label(s.title, systemImage: s.symbol).tag(s)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: showAbout) {
                    Label("About Pavé", systemImage: "info.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.lastError {
                    Banner(text: error) { model.lastError = nil }
                }
                switch model.section {
                case .general: GeneralPane(model: model)
                case .workspaces: WorkspacesPane(model: model, goToKeyboard: { model.section = .keyboard })
                case .zones: ZonesPane(model: model)
                case .taskbar: TaskbarPane(model: model)
                case .keyboard: KeyboardPane(model: model)
                case .apps: AppsPane(model: model)
                }
            }
            .navigationTitle(model.section.title)
        }
        .frame(minWidth: 780, minHeight: 560)
    }
}

/// An amber notice at the top of a settings page.
struct Banner: View {
    var text: String
    var action: (title: String, run: () -> Void)?
    var dismiss: (() -> Void)?

    init(text: String, action: (title: String, run: () -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        self.text = text
        self.action = action
        self.dismiss = dismiss
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action { Button(action.title, action: action.run) }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close")
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4)))
        .padding([.horizontal, .top], 20)
    }
}

/// A grey dot or a green one, and its text.
struct StatusDot: View {
    var ok: Bool
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(text)
        }
    }
}
