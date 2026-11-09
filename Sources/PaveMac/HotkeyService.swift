import CoreGraphics
import Foundation
import PaveCore
import Synchronization

/// Global hotkeys through a CGEventTap, on a dedicated thread so key handling is
/// never delayed by the rest of Pavé (and vice versa).
///
/// Matching uses *logical* modifiers, i.e. what macOS receives after Karabiner
/// or hidutil remapping. Matched key-downs (and their key-ups) are swallowed so
/// the system (Mission Control, Spaces…) and the apps never see them.
public final class HotkeyService: @unchecked Sendable {
    public typealias Trigger = @Sendable (HotkeyAction, Hotkey) -> Void

    /// What the tap sends to the switcher, in order, on the main queue.
    public enum SwitcherKey: Sendable, Equatable {
        /// `latencyStart`: uptime (ns) of the key event, to measure the display latency.
        /// `id` identifies the tap session: `endSession(id)` only ends that one.
        case open(id: Int, sameApp: Bool, backwards: Bool, latencyStart: UInt64)
        case next, previous, left, right, up, down
        case close, quit, enterSearch, type(String), backspace
        case commit, cancel
        /// The session modifiers were released (held mode only).
        case released
        /// A mouse button went down while a session is open (the click itself
        /// goes through): the controller cancels if it is outside the panel.
        case mouseDown
    }

    /// Set before `start()`. Called on the main queue.
    public var onSwitcher: (@MainActor (SwitcherKey) -> Void)?

    /// What the tap sends to a picker (zone layouts ⌃⇧Z, arrangements ⌃⇧A).
    /// A picker stays open once the keys are released, until a choice or Escape.
    public enum PickerKey: Sendable, Equatable {
        /// `action`: which picker.
        case open(id: Int, action: HotkeyAction)
        /// The picker's key again (or Tab): next layout, ⇧ previous.
        case next, previous, left, right, up, down
        /// 1…9: that layout (then, for the zone picker, maybe one of its zones).
        case digit(Int)
        /// A letter (as typed in the active layout): the picker's own command
        /// (E edits a layout, S saves an arrangement), else it closes. Ends the session.
        case letter(String)
        case commit, cancel
    }

    /// Set before `start()`. Called on the main queue.
    public var onPicker: (@MainActor (PickerKey) -> Void)?

    /// Left button seen from the tap (window drags). Points are global,
    /// top-left origin (as AX); `at` is CLOCK_UPTIME_RAW in ns, taken in the tap.
    public enum MouseEvent: Sendable {
        case down(x: Double, y: Double, at: UInt64)
        /// The cursor moved with the button down (at most every `dragInterval`).
        /// `option`: ⌥ held (drag without snapping); `shift`: span zones;
        /// `control`: show zones (when they only show with ctrl).
        case dragged(x: Double, y: Double, option: Bool, shift: Bool, control: Bool, at: UInt64)
        case up(x: Double, y: Double, at: UInt64)
    }

    /// Set before `start()`. Called on the main queue.
    public var onMouse: (@MainActor (MouseEvent) -> Void)?

    /// Left ⌥ pressed and released alone, quickly (the Windows key on a PC
    /// keyboard with the "pc" remapping): opens the launcher.
    /// Set before `start()`. Called on the main queue.
    public var onOptionTap: (@MainActor () -> Void)?
    /// Tap thread only: when left ⌥ went down alone, nil once anything else happened.
    private var optionDownAt: UInt64?
    private var optionTapEnabled = false
    static let leftOptionKey: Int64 = 58
    static let optionTapMax: UInt64 = 500_000_000
    /// Tap thread only.
    private var leftDown = false
    private var lastDragSent: UInt64 = 0
    /// The latest drag not yet delivered: a main thread busy for a moment
    /// gets the newest position, not every stale one in a row.
    private let pendingDrag = Mutex<MouseEvent?>(nil)
    /// ~120 Hz: smooth zones without flooding the main queue.
    static let dragInterval: UInt64 = 8_000_000

    /// A switcher session seen from the tap: while it lasts, every key goes to
    /// the switcher and nothing reaches the apps.
    private struct Session {
        /// The binding's modifiers minus ⇧ (⇧ only reverses): releasing all of
        /// them ends a held session.
        var modifiers: Modifiers
        var triggerKey: UInt16
        var id: Int
        var searching = false
        var lastInput = Date()
        /// A zone picker session: not ended by releasing the modifiers.
        var picker = false
    }
    private var sessionCounter = 0
    static let sessionIdleTimeout: TimeInterval = 30

    private let onTrigger: Trigger
    private let thread = AppThread()
    /// Before `start()`: the initial bindings. After: confined to `thread`.
    private var bindings: [Hotkey: HotkeyAction]
    // Confined to `thread`.
    private var tap: CFMachPort?
    private var session: Session?
    private var layout = KeyboardLayout()
    private var swallowedKeyUps: Set<UInt16> = []

    public init(bindings: [Hotkey: HotkeyAction], onTrigger: @escaping Trigger) {
        self.bindings = bindings
        self.onTrigger = onTrigger
    }

    /// Returns false if the tap cannot be created (Accessibility missing).
    @discardableResult
    public func start() -> Bool {
        thread.name = "pave.hotkeys"
        thread.startAndWait()
        let created = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        thread.perform {
            ok = self.installTap()
            created.signal()
        }
        created.wait()
        Log.info(ok ? "hotkeys active: \(Self.describe(bindings))" : "hotkeys UNAVAILABLE: cannot create event tap")
        return ok
    }

    /// New bindings from a config reload. Keys held down right now keep
    /// swallowing their key-up, so no stray key-up leaks to the apps.
    public func setOptionTap(enabled: Bool) {
        thread.perform {
            self.optionTapEnabled = enabled
            self.optionDownAt = nil
        }
    }

    public func update(bindings new: [Hotkey: HotkeyAction]) {
        thread.perform {
            self.bindings = new
            Log.info("hotkeys updated: \(Self.describe(new))")
        }
    }

    /// The keyboard layout changed (or at start-up): characters for W, Q and search.
    public func update(layout new: KeyboardLayout) {
        thread.perform { self.layout = new }
    }

    /// The switcher ended session `id` (commit, click…): stop capturing keys.
    /// Ignored if the tap is already in a *newer* session: the main thread may
    /// lag behind the keyboard (seen in testing: a late end killed the next
    /// session and its Escape leaked to the frontmost app).
    public func endSession(_ id: Int) {
        thread.perform {
            if self.session?.id == id { self.session = nil }
        }
    }

    static func describe(_ bindings: [Hotkey: HotkeyAction]) -> String {
        bindings.isEmpty ? "none" : bindings.keys.map(\.description).sorted().joined(separator: " ")
    }

    // MARK: - On `thread`

    private func installTap() -> Bool {
        let mask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
            return service.handle(type, event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap that is too slow: turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.info("event tap was disabled (\(type.rawValue)), re-enabled")
            // Keys may have been missed (the ⌃ release among them): never stay stuck.
            if session != nil { endSession(sending: .cancel) }
            return Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            optionDownAt = nil  // ⌥-click, ⌥-drag: not a tap
            if let current = session {
                // A click anywhere closes the picker (it takes no mouse).
                if current.picker { endSession(sending: .cancel) } else { send(.mouseDown) }
            }
            if type == .leftMouseDown {
                leftDown = true
                lastDragSent = 0
                let p = event.location
                sendMouse(.down(x: p.x, y: p.y, at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged:
            // Hot path: throttled, and nothing but a hop to the main queue.
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if leftDown, now - lastDragSent >= Self.dragInterval {
                lastDragSent = now
                let p = event.location
                let flags = event.flags
                sendDrag(.dragged(
                    x: p.x, y: p.y, option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift),
                    control: flags.contains(.maskControl), at: now))
            }
            return Unmanaged.passUnretained(event)

        case .leftMouseUp:
            if leftDown {
                leftDown = false
                let p = event.location
                sendMouse(.up(x: p.x, y: p.y, at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            trackOptionTap(event)
            // ⇧, ⌥ or ⌃ pressed or released mid-drag: the zones react now,
            // not at the next mouse move.
            if leftDown {
                let p = event.location, flags = event.flags
                sendDrag(.dragged(
                    x: p.x, y: p.y, option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift),
                    control: flags.contains(.maskControl), at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
            }
            if let current = session, !current.searching, !current.picker,
                Self.modifiers(of: event.flags).isDisjoint(with: current.modifiers)
            {
                endSession(sending: .released)
            }
            return Unmanaged.passUnretained(event)

        case .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if swallowedKeyUps.remove(keyCode) != nil { return nil }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            optionDownAt = nil  // ⌥ + a key (special characters): not a tap
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if session != nil { return handleSessionKey(keyCode, event) }
            let hotkey = Hotkey(layout.letterKey(keyCode), Self.modifiers(of: event.flags))
            if let (sameApp, backwards) = switcherTrigger(hotkey) {
                swallowedKeyUps.insert(keyCode)
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
                var mods = hotkey.modifiers
                mods.remove(.shift)
                sessionCounter += 1
                session = Session(modifiers: mods.isEmpty ? .shift : mods, triggerKey: keyCode, id: sessionCounter)
                send(.open(id: sessionCounter, sameApp: sameApp, backwards: backwards, latencyStart: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
                watchIdle()
                return nil
            }
            if let picker = bindings[hotkey], picker == .zonePicker || picker == .arrangementPicker {
                swallowedKeyUps.insert(keyCode)
                guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }
                sessionCounter += 1
                session = Session(modifiers: [], triggerKey: keyCode, id: sessionCounter, picker: true)
                sendPicker(.open(id: sessionCounter, action: picker))
                watchIdle()
                return nil
            }
            guard let action = bindings[hotkey] else { return Unmanaged.passUnretained(event) }
            swallowedKeyUps.insert(keyCode)
            // Holding the keys repeats the key-down: act once, swallow the repeats.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onTrigger(action, hotkey)
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// ⌃Tab (or the configured key) opens the switcher; the same key with ⇧ opens it backwards.
    private func switcherTrigger(_ hotkey: Hotkey) -> (sameApp: Bool, backwards: Bool)? {
        func kind(_ action: HotkeyAction?) -> Bool? {
            switch action {
            case .switcher: false
            case .switcherSameApp: true
            default: nil
            }
        }
        if let sameApp = kind(bindings[hotkey]) { return (sameApp, false) }
        guard hotkey.modifiers.contains(.shift) else { return nil }
        var unshifted = hotkey
        unshifted.modifiers.remove(.shift)
        return kind(bindings[unshifted]).map { ($0, true) }
    }

    /// While a session is open, every key-down is the switcher's.
    private func handleSessionKey(_ keyCode: UInt16, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard var current = session else { return Unmanaged.passUnretained(event) }
        if current.picker { return handlePickerKey(keyCode, event) }
        swallowedKeyUps.insert(keyCode)
        current.lastInput = Date()
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let shift = event.flags.contains(.maskShift)
        var key: SwitcherKey?
        switch keyCode {
        case current.triggerKey, Hotkey.Key.tab: key = shift ? .previous : .next
        case Hotkey.Key.leftArrow: key = .left
        case Hotkey.Key.rightArrow: key = .right
        case Hotkey.Key.upArrow: key = .up
        case Hotkey.Key.downArrow: key = .down
        case 53:  // escape
            endSession(sending: .cancel)
            return nil
        case 36, 76:  // return, keypad enter
            endSession(sending: .commit)
            return nil
        case 51:  // delete
            if current.searching { key = .backspace }
        case 49 where !current.searching:  // space
            if !repeated {
                current.searching = true
                key = .enterSearch
            }
        default:
            let character = layout.character(keyCode, shift: shift)
            if current.searching {
                key = character.map { .type($0) }
            } else if !repeated {
                switch character?.lowercased() {
                case "w": key = .close
                case "q": key = .quit
                default: break
                }
            }
        }
        session = current
        if let key { send(key) }
        return nil
    }

    private func endSession(sending key: SwitcherKey) {
        let picker = session?.picker == true
        session = nil
        if picker { sendPicker(key == .commit ? .commit : .cancel) } else { send(key) }
    }

    /// While the picker is open, every key-down is its own.
    private func handlePickerKey(_ keyCode: UInt16, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard var current = session else { return Unmanaged.passUnretained(event) }
        swallowedKeyUps.insert(keyCode)
        current.lastInput = Date()
        session = current
        let shift = event.flags.contains(.maskShift)
        let key: PickerKey?
        switch keyCode {
        case current.triggerKey, Hotkey.Key.tab: key = shift ? .previous : .next
        case Hotkey.Key.leftArrow: key = .left
        case Hotkey.Key.rightArrow: key = .right
        case Hotkey.Key.upArrow: key = .up
        case Hotkey.Key.downArrow: key = .down
        case 53: key = nil; endSession(sending: .cancel)  // escape
        case 36, 76: key = nil; endSession(sending: .commit)  // return, keypad enter
        default:
            if let index = Hotkey.Key.digits.firstIndex(of: keyCode) {
                // The picker closes by itself (onClose ends the session): a
                // digit may be followed by another (layout, then zone).
                key = .digit(index + 1)
            } else if let c = layout.character(keyCode, shift: false)?.lowercased(), c.count == 1, c.first!.isLetter {
                self.session = nil  // what it opens takes the keyboard, or the picker closes
                key = .letter(c)
            } else {
                key = nil
            }
        }
        if let key { sendPicker(key) }
        return nil
    }

    private func sendPicker(_ key: PickerKey) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onPicker?(key) }
        }
    }

    /// Left ⌥ down with no other modifier starts a tap; released within
    /// `optionTapMax` with nothing in between, it fires.
    private func trackOptionTap(_ event: CGEvent) {
        guard optionTapEnabled, session == nil else { return optionDownAt = nil }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = Self.modifiers(of: event.flags)
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if keyCode == Self.leftOptionKey, modifiers == [.option], !event.flags.contains(.maskSecondaryFn) {
            optionDownAt = now  // pressed, alone
        } else if keyCode == Self.leftOptionKey, modifiers.isEmpty, let down = optionDownAt {
            optionDownAt = nil
            guard now - down <= Self.optionTapMax, let handler = onOptionTap else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { handler() } }
        } else {
            optionDownAt = nil  // another modifier joined in
        }
    }

    private func sendMouse(_ event: MouseEvent) {
        guard onMouse != nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onMouse?(event) }
        }
    }

    /// Drags share one slot: a hop already queued delivers the newest one.
    /// Down and up go through `sendMouse`, queued after it: the order holds.
    private func sendDrag(_ event: MouseEvent) {
        guard onMouse != nil else { return }
        let queued = pendingDrag.withLock { slot in
            defer { slot = event }
            return slot != nil
        }
        guard !queued else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let latest = self.pendingDrag.withLock({ slot in
                defer { slot = nil }
                return slot
            }) else { return }
            MainActor.assumeIsolated { self.onMouse?(latest) }
        }
    }

    private func send(_ key: SwitcherKey) {
        // The main queue keeps the keys in order (Task would not guarantee it).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onSwitcher?(key) }
        }
    }

    /// Safety net: a session nobody types into for a while is cancelled, so a
    /// missed ⌃ release can never leave the keyboard captured.
    private func watchIdle() {
        thread.after(5) { [weak self] in
            guard let self, let current = self.session else { return }
            if Date().timeIntervalSince(current.lastInput) > Self.sessionIdleTimeout {
                Log.info("switcher: no key for \(Int(Self.sessionIdleTimeout)) s, cancelled")
                self.endSession(sending: .cancel)
            } else {
                self.watchIdle()
            }
        }
    }

    /// Keeps only ⌃⌥⇧⌘. Arrow keys also carry the fn and numeric-pad flags,
    /// which must not take part in matching.
    static func modifiers(of flags: CGEventFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
}
