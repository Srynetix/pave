import AppKit
import SwiftUI

/// The Settings and About windows (one of each), and the main menu they need:
/// Pavé is an accessory app, without one ⌘W, ⌘C or ⌘V would do nothing.
@MainActor
final class PaveWindows: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private var settings: NSWindow?
    private var about: NSWindow?
    private var onboarding: NSWindow?
    /// The welcome guide was finished ("Start using Pavé").
    var onboardingDone: () -> Void = {}
    /// Called when the Settings window opens (fresh data).
    var onOpen: () -> Void = {}

    init(model: SettingsModel) {
        self.model = model
        super.init()
        NSApp.mainMenu = Self.mainMenu()
    }

    var isSettingsVisible: Bool { settings?.isVisible == true }

    func showSettings() {
        onOpen()
        let window = settings ?? makeWindow(
            title: String(localized: "Pavé Settings"), size: NSSize(width: 880, height: 640), resizable: true,
            content: SettingsView(model: model, showAbout: { [weak self] in self?.showAbout() }))
        window.setFrameAutosaveName("PaveSettings")
        settings = window
        bringToFront(window)
    }

    func showAbout() {
        let window = about ?? makeWindow(
            title: String(localized: "About Pavé"), size: NSSize(width: 520, height: 400), resizable: false,
            content: AboutView(model: model))
        about = window
        bringToFront(window)
    }

    /// The welcome guide. `page`: where to open it (snapshots).
    func showOnboarding(page: Int = 0) {
        onOpen()
        onboarding?.close()
        let window = makeWindow(
            title: String(localized: "Welcome to Pavé"), size: NSSize(width: 640, height: 520), resizable: false,
            content: OnboardingView(model: model, finish: { [weak self] in
                self?.onboardingDone()
                self?.onboarding?.close()
            }, initialPage: page))
        onboarding = window
        bringToFront(window)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, resizable: Bool, content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    private func bringToFront(_ window: NSWindow) {
        // After the status menu has closed: opened from inside its tracking
        // loop, the window could stay off screen.
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// `pave spike shot`: draws Pavé's own window into a PNG (no screen
    /// recording permission needed). Only Pavé's windows: never other apps'.
    func snapshot(_ which: String, dark: Bool, to path: String) -> String {
        guard let window = which == "about" ? about : which == "onboarding" ? onboarding : settings, let view = window.contentView else {
            return "open the \(which) window first"
        }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "no bitmap" }
        view.cacheDisplay(in: view.bounds, to: rep)
        window.appearance = nil
        guard let data = rep.representation(using: .png, properties: [:]) else { return "no PNG" }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { return "\(error.localizedDescription)" }
        return "wrote \(path)"
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settings { model.stopRecording() }
    }

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("Pavé", [item(String(localized: "Hide Pavé"), #selector(NSApplication.hide(_:)), "h")])
        submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), Selector(("undo:")), "z"),
            item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(String(localized: "Window"), [
            item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"),
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }
}
