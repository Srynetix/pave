// SPDX-License-Identifier: MIT OR Apache-2.0
import AppKit
import IOKit
import IOKit.hid
import PaveCore

/// Keeps every keyboard remapped.
///
/// `hidutil` mappings live in the HID services of a device: they are lost when
/// the device goes away (unplug, Bluetooth reconnect, reboot). So Pavé applies
/// them whenever a keyboard **appears** (IOKit notification, no permission
/// needed), at **start-up**, on **wake** and when the **config** changes, then
/// reads them back to check. It replaces the provisional LaunchAgent of M0.
///
/// Pavé owns UserKeyMapping on the keyboards: a keyboard that is skipped, or
/// all of them when the remap is turned off, get an empty mapping, but only if
/// Pavé had set one during this run (a hand-made hidutil mapping is never
/// touched otherwise). While Karabiner runs, Pavé does nothing: Karabiner seizes
/// the keyboards, and a second remap would stack on its virtual keyboard.
@MainActor
public final class KeyboardRemapService {
    public enum KeyboardState: Equatable, Sendable {
        case pending
        case applied(count: Int)
        case stock
        case skipped
        case failed(String)
    }

    public struct Settings: Equatable, Sendable {
        public var enabled: Bool
        public var preset: KeyRemap.Preset
        public var skip: Set<String>
        public init(enabled: Bool, preset: KeyRemap.Preset, skip: Set<String>) {
            self.enabled = enabled
            self.preset = preset
            self.skip = skip
        }
    }

    /// Called on the main thread when a keyboard or its state changes (menu).
    public var onChange: (() -> Void)?
    public private(set) var settings: Settings
    /// Keyboards connected now, by `configID`, with their state.
    public private(set) var keyboards: [String: (keyboard: KeyRemap.Keyboard, state: KeyboardState)] = [:]
    public private(set) var karabinerRunning = false

    /// IOKit registry entry → keyboard (one device can show several entries).
    private var entries: [UInt64: String] = [:]
    /// What Pavé set on each keyboard during this run (to undo it cleanly).
    private var applied: [String: [KeyRemap.Mapping]] = [:]
    private var pending: [String: String] = [:]  // configID → reason
    private var pendingSince: [String: UInt64] = [:]
    private var scheduled = false
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var wakeObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    private let worker = DispatchQueue(label: "pave.keyboard-remap")

    /// A just-plugged device gets its HID services a bit after it appears:
    /// wait, then apply; check and retry if the mapping did not stick.
    static let settleDelay: TimeInterval = 0.1
    static let retryDelays: [TimeInterval] = [0.5, 1, 2]

    public init(settings: Settings) {
        self.settings = settings
    }

    public func start() {
        guard notifyPort == nil else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        CFRunLoopAddSource(
            CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for (type, callback) in [
            (kIOFirstMatchNotification, Self.appearedCallback), (kIOTerminatedNotification, Self.goneCallback),
        ] {
            let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
            matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
            matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Keyboard
            var iterator: io_iterator_t = 0
            // The call consumes one reference to the dictionary.
            let dict = Unmanaged.passRetained(matching as CFDictionary).takeUnretainedValue()
            let result = IOServiceAddMatchingNotification(port, type, dict, callback, me, &iterator)
            guard result == KERN_SUCCESS else {
                Log.info("keyboard remap: IOKit notification failed (\(result)), keyboards are only remapped at start")
                continue
            }
            iterators.append(iterator)
            // Arms the notification, and lists the keyboards already there.
            drain(iterator, appeared: type == kIOFirstMatchNotification, reason: "start")
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reapplyAll(reason: "wake") } }
        // Karabiner quit (menu or settings app): the keyboards are free again.
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier?.hasPrefix("org.pqrs.") == true else { return }
            MainActor.assumeIsolated { self?.reapplyAll(reason: "Karabiner quit") }
        }
        Log.info(
            "keyboard remap: \(settings.enabled ? "on, preset \(settings.preset.rawValue)" : "off"), \(keyboards.count) keyboard(s): \(keyboards.values.map(\.keyboard.description).sorted().joined(separator: ", "))"
        )
    }

    public func update(settings new: Settings) {
        guard new != settings else { return }
        settings = new
        reapplyAll(reason: "config")
    }

    public func reapplyAll(reason: String) {
        for id in keyboards.keys { schedule(id, reason: reason) }
    }

    // MARK: - Devices

    private static let appearedCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let me = Unmanaged<KeyboardRemapService>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { me.drain(iterator, appeared: true, reason: "plugged") }
    }

    private static let goneCallback: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        let me = Unmanaged<KeyboardRemapService>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { me.drain(iterator, appeared: false, reason: "unplugged") }
    }

    private func drain(_ iterator: io_iterator_t, appeared: Bool, reason: String) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            if appeared {
                guard let keyboard = Self.keyboard(service) else { continue }
                entries[entryID] = keyboard.configID
                if keyboards[keyboard.configID] == nil {
                    keyboards[keyboard.configID] = (keyboard, .pending)
                    if reason != "start" { Log.info("keyboard remap: \(keyboard) connected") }
                }
                schedule(keyboard.configID, reason: reason)
            } else if let id = entries.removeValue(forKey: entryID), !entries.values.contains(id) {
                Log.info("keyboard remap: \(keyboards[id]?.keyboard.description ?? id) disconnected")
                keyboards[id] = nil
                pending[id] = nil
                applied[id] = nil  // its mapping went away with it
                onChange?()
            }
        }
    }

    private static func keyboard(_ service: io_service_t) -> KeyRemap.Keyboard? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let name = property(kIOHIDProductKey) as? String ?? "keyboard"
        let manufacturer = property(kIOHIDManufacturerKey) as? String ?? ""
        // Karabiner's virtual keyboard already carries Karabiner's remap.
        if name.localizedCaseInsensitiveContains("karabiner") || manufacturer.contains("pqrs") { return nil }
        let builtIn = (property(kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false
        return KeyRemap.Keyboard(
            vendorID: property(kIOHIDVendorIDKey) as? Int ?? 0, productID: property(kIOHIDProductIDKey) as? Int ?? 0,
            builtIn: builtIn, name: name, locationID: property(kIOHIDLocationIDKey) as? Int ?? 0)
    }

    // MARK: - Applying

    private func schedule(_ id: String, reason: String) {
        if pending[id] == nil { pendingSince[id] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        pending[id] = pending[id] ?? reason
        guard !scheduled else { return }
        scheduled = true
        let delay = reason == "plugged" ? Self.settleDelay : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { self.flush() }
        }
    }

    private func flush() {
        scheduled = false
        let batch = pending
        pending = [:]
        let since = pendingSince
        let settings = self.settings
        worker.async {
            let karabiner = Self.isKarabinerRunning()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.setKarabiner(karabiner)
                    for (id, reason) in batch.sorted(by: { $0.key < $1.key }) {
                        guard let keyboard = self.keyboards[id]?.keyboard else { continue }
                        self.apply(
                            keyboard, reason: reason, since: since[id] ?? 0, settings: settings, karabiner: karabiner)
                    }
                }
            }
        }
    }

    private func setKarabiner(_ running: Bool) {
        guard running != karabinerRunning else { return }
        karabinerRunning = running
        Log.info(
            running
                ? "keyboard remap: Karabiner-Elements is running, Pavé leaves the keyboards to it"
                : "keyboard remap: Karabiner-Elements is no longer running")
        onChange?()
    }

    private func apply(
        _ keyboard: KeyRemap.Keyboard, reason: String, since: UInt64, settings: Settings, karabiner: Bool,
        attempt: Int = 0
    ) {
        let id = keyboard.configID
        let skipped = settings.skip.contains(id)
        let wanted = settings.enabled && !skipped ? KeyRemap.mappings(for: keyboard, preset: settings.preset) : []
        let state: KeyboardState = skipped ? .skipped : (wanted.isEmpty ? .stock : .applied(count: wanted.count))
        guard !karabiner else { return }
        // Nothing to set, and nothing of Pavé's to remove: leave it alone.
        if wanted.isEmpty, applied[id] == nil {
            keyboards[id]?.state = state
            onChange?()
            return
        }
        let queuedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        worker.async {
            let setStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let result = Self.set(wanted, on: keyboard)
            let setMs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - setStart) / 1_000_000
            let waitMs = Double(setStart - queuedAt) / 1_000_000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.keyboards[id] != nil else { return }  // unplugged meanwhile
                    let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - since) / 1_000_000
                    if let error = result {
                        if attempt < Self.retryDelays.count {
                            Log.info("keyboard remap: \(keyboard) after \(reason): \(error), retrying")
                            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) {
                                MainActor.assumeIsolated {
                                    guard let current = self.keyboards[id]?.keyboard else { return }
                                    self.apply(
                                        current, reason: reason, since: since, settings: self.settings,
                                        karabiner: self.karabinerRunning, attempt: attempt + 1)
                                }
                            }
                            return
                        }
                        self.keyboards[id]?.state = .failed(error)
                        Log.info("keyboard remap: \(keyboard) after \(reason): FAILED (\(error)), \(Int(ms)) ms")
                    } else {
                        self.applied[id] = wanted.isEmpty ? nil : wanted
                        self.keyboards[id]?.state = state
                        // Target: < 1 s after the plug, the wake or the start.
                        Log.info(
                            "keyboard remap: \(keyboard) after \(reason): "
                                + (wanted.isEmpty ? "mapping removed" : "\(wanted.count) mapping(s) applied")
                                + ", verified, \(String(format: "%.0f", ms)) ms"
                                + (attempt > 0 ? " (attempt \(attempt + 1))" : "")
                                + " [hidutil \(Int(setMs)) ms, queued \(Int(waitMs)) ms]")
                    }
                    self.onChange?()
                }
            }
        }
    }

    // MARK: - hidutil (worker queue)

    /// Sets the mapping, reads it back. nil = verified.
    private nonisolated static func set(_ mappings: [KeyRemap.Mapping], on keyboard: KeyRemap.Keyboard) -> String? {
        let set = run(["property", "--matching", keyboard.matching, "--set", KeyRemap.hidutilProperty(mappings)])
        guard set.status == 0 else { return "hidutil --set exit \(set.status)" }
        let get = run(["property", "--matching", keyboard.matching, "--get", "UserKeyMapping"])
        guard get.status == 0 else { return "hidutil --get exit \(get.status)" }
        // One block per HID service of the device; every mapped service lists all entries.
        let found = get.output.components(separatedBy: "HIDKeyboardModifierMappingSrc").count - 1
        if mappings.isEmpty { return found == 0 ? nil : "\(found) entries still there" }
        return found >= mappings.count ? nil : "mapping not taken (\(found)/\(mappings.count) entries)"
    }

    private nonisolated static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        do {
            let result = try Shell.run("/usr/bin/hidutil", arguments)
            return (result.status, result.text + result.errorText)
        } catch {
            return (-1, "\(error)")
        }
    }

    /// Karabiner seizes the keyboards only while its user-session side runs
    /// (menu, session agent, user Core-Service); its root daemons and virtual
    /// HID driver stay up after "Quit". EventViewer is only a viewer.
    nonisolated static func isKarabinerRunning() -> Bool {
        // Executable paths only (`comm`), never the arguments: a command line
        // that merely mentions Karabiner (an editor, a shell) must not count.
        guard let result = try? Shell.run("/bin/ps", ["-A", "-o", "uid=,comm="]) else { return false }
        return isKarabinerRunning(psOutput: result.text, uid: Int(getuid()))
    }

    /// `ps -o uid=,comm=` lines: "  501 /Applications/…/Karabiner-Menu".
    nonisolated static func isKarabinerRunning(psOutput: String, uid: Int) -> Bool {
        psOutput.split(separator: "\n").contains { line in
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let owner = Int(trimmed[..<space]) else { return false }
            let name = trimmed[space...].split(separator: "/").last.map { $0.lowercased() } ?? ""
            if name.contains("karabiner_grabber") { return true }
            return owner == uid && name.contains("karabiner") && !name.contains("eventviewer")
        }
    }

    // MARK: - Report

    /// Text of `pave keyboards` and of the menu: names and IDs only.
    public var report: [String] {
        keyboards.values.sorted { $0.keyboard.configID < $1.keyboard.configID }.map { entry in
            let state: String
            switch entry.state {
            case .pending: state = karabinerRunning ? "left to Karabiner" : "pending"
            case .applied(let n): state = "remapped (\(n) mappings)"
            case .stock: state = "stock"
            case .skipped: state = "skipped (keyboard.skip)"
            case .failed(let e): state = "FAILED: \(e)"
            }
            return "\(entry.keyboard): \(state)"
        }
    }
}
