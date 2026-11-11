// SPDX-License-Identifier: MIT OR Apache-2.0
import Carbon.HIToolbox
import Foundation
import PaveCore

/// Characters produced by each key with the current keyboard layout (French-PC
/// today), without and with ⇧. The switcher needs *characters*, not key
/// positions: W and Q are the AZERTY letters, and the search types what the
/// user sees on the keys.
///
/// The Text Input Source API must be used on the main thread: the table is
/// built there, then handed to the event tap thread as an immutable value.
public struct KeyboardLayout: Sendable {
    public var plain: [UInt16: String] = [:]
    public var shifted: [UInt16: String] = [:]

    /// Letters by what they type: the US QWERTY key of the letter this key
    /// types in the active layout (the AZERTY Z key → the QWERTY Z key), so
    /// letter shortcuts follow the layout. Other keys stay as they are.
    public func letterKey(_ keyCode: UInt16) -> UInt16 {
        guard let letter = plain[keyCode]?.lowercased(), letter.count == 1, let c = letter.first, c >= "a", c <= "z",
            let qwerty = Hotkey.keyCodes[letter]
        else { return keyCode }
        return qwerty
    }

    public func character(_ keyCode: UInt16, shift: Bool) -> String? {
        (shift ? shifted : plain)[keyCode]
    }

    @MainActor
    public static func current() -> KeyboardLayout {
        var layout = KeyboardLayout()
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return layout }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in UInt16(0)..<128 {
                for shift in [false, true] {
                    var deadKeys: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                    let status = UCKeyTranslate(
                        base, code, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let text = String(utf16CodeUnits: chars, count: length)
                    // Control characters (return, tab, arrows…) are not text.
                    guard text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { continue }
                    if shift { layout.shifted[code] = text } else { layout.plain[code] = text }
                }
            }
        }
        return layout
    }

    /// Calls `handler` on the main thread whenever the user changes layout.
    @MainActor
    public static func observeChanges(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { handler() } }
    }
}
