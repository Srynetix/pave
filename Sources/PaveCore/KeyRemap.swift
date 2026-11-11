// SPDX-License-Identifier: MIT OR Apache-2.0
/// Per-keyboard key remapping.
///
/// Pure: says *which* mapping each keyboard gets. PaveMac detects keyboards
/// and applies the result with `hidutil` (UserKeyMapping).
public enum KeyRemap {
    /// A HID usage as hidutil wants it: (usage page << 32) | usage.
    public enum Key: UInt64, Sendable, CaseIterable {
        case leftControl = 0x7_0000_00E0
        case leftOption = 0x7_0000_00E2
        case leftCommand = 0x7_0000_00E3
        case rightControl = 0x7_0000_00E4
        case rightOption = 0x7_0000_00E6
        case rightCommand = 0x7_0000_00E7
        /// `§` / `` ` `` key, left of 1 on ISO keyboards.
        case grave = 0x7_0000_0035
        /// `<` / `>` key, right of left Shift on ISO keyboards.
        case nonUSBackslash = 0x7_0000_0064
        /// The `fn` / globe key of Apple keyboards (Apple vendor top-case page).
        case fn = 0xFF_0000_0003
    }

    public struct Mapping: Equatable, Hashable, Sendable, CustomStringConvertible {
        public var from: Key
        public var to: Key
        public init(_ from: Key, _ to: Key) {
            self.from = from
            self.to = to
        }
        public var description: String { "\(from)→\(to)" }
    }

    /// A keyboard as Pavé sees it. The built-in one has no vendor ID (0).
    public struct Keyboard: Hashable, Sendable, CustomStringConvertible {
        public var vendorID: Int
        public var productID: Int
        public var builtIn: Bool
        public var name: String
        /// Where the device is attached; 0 if unknown. Narrows the built-in match.
        public var locationID: Int

        public init(vendorID: Int, productID: Int, builtIn: Bool, name: String, locationID: Int = 0) {
            self.vendorID = vendorID
            self.productID = productID
            self.builtIn = builtIn
            self.name = name
            self.locationID = locationID
        }

        /// "vendor:product" in decimal, as written in `keyboard.skip`; "built-in".
        public var configID: String { builtIn ? "built-in" : "\(vendorID):\(productID)" }

        /// hidutil `--matching` argument: the **whole device**, never one service
        /// (narrowing to the keyboard usage hits a service that does not remap
        /// on macOS 27). The built-in keyboard has no vendor ID:
        /// "Built-In" alone also hits ~130 sensor and power services (3.7 s per
        /// set), so its location narrows it to the keyboard/trackpad (9 services).
        public var matching: String {
            if builtIn {
                return locationID != 0 ? #"{"Built-In":1,"LocationID":\#(locationID)}"# : #"{"Built-In":1}"#
            }
            return #"{"VendorID":\#(vendorID),"ProductID":\#(productID)}"#
        }

        public var description: String { "\(name) (\(configID))" }
    }

    public enum Preset: String, Sendable, CaseIterable {
        /// PC habits on Mac keyboards (see `mappings(for:preset:)`).
        case pc
        /// Stock keyboard.
        case none
    }

    /// The mapping a keyboard gets.
    ///
    /// Preset "pc" (taken from a Karabiner profile):
    /// - every keyboard: left ⌘ → ⌃, right ⌘ → right ⌥;
    /// - built-in: fn → ⌘, left ⌃ → fn (bottom row fn ⌃ ⌥ ⌘ becomes ⌘ fn ⌥ ⌃).
    ///   **No** `§` ↔ `<` swap: with hidutil, macOS's own ISO handling already
    ///   gives `²` and `<` in the right place (A/B tested; Karabiner
    ///   needed the swap because it grabs the keys before that handling);
    /// - external (Mac layout, e.g. Logitech): left ⌃ → ⌘ (⌃ ⌥ ⌘ becomes ⌘ ⌥ ⌃).
    ///   No `§` ↔ `<` swap either: on the Logitech MX Keys S too, it put `²`
    ///   and `<` the wrong way round.
    public static func mappings(for keyboard: Keyboard, preset: Preset) -> [Mapping] {
        switch preset {
        case .none: return []
        case .pc:
            let common = [Mapping(.leftCommand, .leftControl), Mapping(.rightCommand, .rightOption)]
            return keyboard.builtIn
                ? common + [Mapping(.fn, .leftCommand), Mapping(.leftControl, .fn)]
                : common + [Mapping(.leftControl, .leftCommand)]
        }
    }

    /// hidutil `--set` argument. An empty list removes Pavé's mapping.
    public static func hidutilProperty(_ mappings: [Mapping]) -> String {
        let items = mappings.map {
            #"{"HIDKeyboardModifierMappingSrc":\#($0.from.rawValue),"HIDKeyboardModifierMappingDst":\#($0.to.rawValue)}"#
        }
        return #"{"UserKeyMapping":["# + items.joined(separator: ",") + "]}"
    }
}
