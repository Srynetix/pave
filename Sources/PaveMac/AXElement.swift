import ApplicationServices
import Foundation
import PaveCore

/// Thin, typed accessors over AXUIElement. Every call is a synchronous IPC to
/// the target app: only call these from that app's AppThread.
extension AXUIElement {
    func copy(_ attribute: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(self, attribute as CFString, &value)
        return (value, error)
    }

    func string(_ attribute: String) -> String? { copy(attribute).value as? String }

    func bool(_ attribute: String) -> Bool? { (copy(attribute).value as? NSNumber)?.boolValue }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = copy(attribute).value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Position (top-left, global coordinates) and size combined.
    var frame: Rect? {
        guard let posValue = copy(kAXPositionAttribute).value,
            let sizeValue = copy(kAXSizeAttribute).value,
            CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, attribute as CFString, value)
    }

    @discardableResult
    func setPosition(x: Double, y: Double) -> AXError {
        var point = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return set(kAXPositionAttribute, value)
    }

    @discardableResult
    func setSize(width: Double, height: Double) -> AXError {
        var size = CGSize(width: width, height: height)
        guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
        return set(kAXSizeAttribute, value)
    }

    var windowID: WindowID? {
        PrivateAPI.windowID(of: self).map { WindowID($0) }
    }
}
