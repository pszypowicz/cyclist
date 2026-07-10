import ApplicationServices

// Thin helpers over the Accessibility C API. All calls are bounded by a short
// global messaging timeout so an unresponsive app cannot stall the switcher
// (a stalled event tap callback gets disabled by the system).
enum AX {
    static func configureGlobalTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.05)
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else {
            return []
        }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            let element = item as! AXUIElement
            // Finder reports the desktop as a full-screen AXScrollArea in its
            // window list; only real AXWindow elements count.
            guard string(element, kAXRoleAttribute) == kAXWindowRole as String else { return nil }
            return element
        }
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ flag: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, flag as CFTypeRef)
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}
