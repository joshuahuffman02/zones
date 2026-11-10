import AppKit
import ApplicationServices

/// Private but stable for a decade, and used by every non-App Store window manager.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &v) == .success else { return nil }
        return v
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { (value(attribute) as? NSNumber)?.boolValue }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXUIElement] {
        (value(attribute) as? [AnyObject])?.compactMap { obj in
            CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
        } ?? []
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    var pid: pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(self, &p) == .success ? p : nil
    }

    var position: CGPoint? {
        guard let v = value(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v = value(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    func setPosition(_ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { set(kAXPositionAttribute, v) }
    }

    func setSize(_ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { set(kAXSizeAttribute, v) }
    }

    /// Size, then position, then size again: the first size can be clamped at the old position.
    func setFrame(_ r: CGRect) {
        setSize(r.size)
        setPosition(r.origin)
        setSize(r.size)
    }
}

/// Converts between AppKit screen coordinates (bottom-left origin) and Accessibility (top-left).
enum Coords {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The same flip, the other way.
    static func toNS(_ r: CGRect) -> CGRect { toAX(r) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Window IDs that still exist anywhere (any Space), from the window server.
func existingWindowIDs() -> Set<CGWindowID> {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
}

/// Normal-layer windows visible on the current Space. Cheap enough to poll.
func onScreenWindowIDs() -> Set<CGWindowID> {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return Set(list.compactMap { info in
        (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            ? (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value : nil
    })
}
