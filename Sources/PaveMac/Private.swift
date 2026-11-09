// ALL private macOS APIs used by Pavé live in this file, and only here: the
// raw symbols are fileprivate, the rest of Pavé calls the `PrivateAPI`
// wrappers below. Each one is a risk on every macOS update: keep this list
// short and document a fallback for each.

import ApplicationServices

enum PrivateAPI {
    /// AXUIElement (window) → CGWindowID. Used by AltTab, Rectangle, AeroSpace.
    /// Fallback if it ever disappears: match AX frames/titles against CGWindowListCopyWindowInfo.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The Spaces (ids) holding a window: current, other and fullscreen ones.
    static func spaces(ofWindow id: CGWindowID) -> [UInt64] {
        let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [NSNumber(value: id)] as CFArray)?
            .takeRetainedValue() as? [NSNumber]
        return spaces?.map(\.uint64Value) ?? []
    }

    /// The Space shown on each display (ids).
    static func currentSpaces() -> Set<UInt64> {
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] ?? []
        return Set(displays.compactMap {
            (($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
        })
    }
}

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
fileprivate func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - SkyLight / CGS (windows of other native Spaces)
// Exported by CoreGraphics under their CGS names (no private framework to link).
// Fallback if they disappear: a grace period before forgetting a window that
// vanished from AX.

fileprivate typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
fileprivate func CGSMainConnectionID() -> CGSConnectionID

/// Spaces (ids) holding each window. Mask 0x7: current, other and fullscreen Spaces.
@_silgen_name("CGSCopySpacesForWindows")
fileprivate func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

/// Per display: its UUID, its current Space and every Space (id, type: 0 user, 4 fullscreen).
@_silgen_name("CGSCopyManagedDisplaySpaces")
fileprivate func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>?
