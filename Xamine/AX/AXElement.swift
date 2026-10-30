import ApplicationServices
import Foundation
import CoreGraphics

/// Private but long-stable API that returns the CGWindowID backing an AX window element.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin wrapper over `AXUIElement` that reads attributes in batches.
struct AXElement {
    let raw: AXUIElement

    static func application(pid: pid_t) -> AXElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        return AXElement(raw: app)
    }

    /// Attributes read for every node, in this order.
    static let scanAttributes: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute,
        kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXValueAttribute, kAXPlaceholderValueAttribute, kAXHelpAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
        kAXChildrenAttribute,
    ]

    /// Reads `names` in a single IPC round trip. Missing attributes come back as `nil`.
    func values(_ names: [String]) -> [String: Any] {
        var result: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(raw, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
        guard error == .success, let array = result as? [Any] else { return [:] }
        var dict: [String: Any] = [:]
        for (name, value) in zip(names, array) {
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID(),
               AXValueGetType(value as! AXValue) == .axError {
                continue
            }
            dict[name] = value
        }
        return dict
    }

    func attribute(_ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw, name as CFString, &value) == .success else { return nil }
        return value
    }

    var children: [AXElement] {
        (attribute(kAXChildrenAttribute) as? [AXUIElement])?.map(AXElement.init) ?? []
    }

    var windows: [AXElement] {
        (attribute(kAXWindowsAttribute) as? [AXUIElement])?.map(AXElement.init) ?? []
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(raw, &id) == .success ? id : nil
    }

    var frame: CGRect? {
        let dict = values([kAXPositionAttribute, kAXSizeAttribute])
        return Self.frame(from: dict)
    }

    static func frame(from dict: [String: Any]) -> CGRect? {
        guard let posValue = dict[kAXPositionAttribute], let sizeValue = dict[kAXSizeAttribute] else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Converts an arbitrary attribute value to a short display string.
    static func describe(_ value: Any?) -> String? {
        switch value {
        case nil: return nil
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let attributed as NSAttributedString: return attributed.string
        case let url as URL: return url.absoluteString
        default:
            let ref = value as CFTypeRef
            if CFGetTypeID(ref) == AXUIElementGetTypeID() { return nil }
            if CFGetTypeID(ref) == AXValueGetTypeID() {
                let axValue = ref as! AXValue
                switch AXValueGetType(axValue) {
                case .cgPoint:
                    var p = CGPoint.zero
                    AXValueGetValue(axValue, .cgPoint, &p)
                    return "(\(Int(p.x)), \(Int(p.y)))"
                case .cgSize:
                    var s = CGSize.zero
                    AXValueGetValue(axValue, .cgSize, &s)
                    return "\(Int(s.width))×\(Int(s.height))"
                case .cfRange:
                    var r = CFRange()
                    AXValueGetValue(axValue, .cfRange, &r)
                    return "\(r.location)…\(r.location + r.length)"
                default: return nil
                }
            }
            return nil
        }
    }
}
