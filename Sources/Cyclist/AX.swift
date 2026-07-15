import ApplicationServices

// Maps an AX window element to its CGWindowID; there is no public API for
// this direction.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

// A window that qualifies for the switcher, with the attributes both list
// providers need.
struct AXWindowInfo {
    let element: AXUIElement
    let title: String?  // nil when empty or unreadable
    let isMinimized: Bool
    let windowID: Int?
}

// Thin helpers over the Accessibility C API. All calls are bounded by a short
// global messaging timeout so an unresponsive app cannot stall the switcher
// (a stalled event tap callback gets disabled by the system).
enum AX {
    // Standard and dialog windows of the app, with title, minimized state,
    // and CG window id. A window whose subrole is unreadable passes the
    // filter (matching apps that report no subrole at all).
    static func qualifiedWindows(pid: pid_t) -> [AXWindowInfo] {
        windows(pid: pid).compactMap { window in
            if let subrole = string(window, kAXSubroleAttribute) {
                guard subrole == kAXStandardWindowSubrole as String
                        || subrole == kAXDialogSubrole as String else { return nil }
            }
            let title = string(window, kAXTitleAttribute)
            return AXWindowInfo(
                element: window,
                title: (title?.isEmpty == false) ? title : nil,
                isMinimized: bool(window, kAXMinimizedAttribute) == true,
                windowID: windowID(of: window)
            )
        }
    }

    static func windowID(of element: AXUIElement) -> Int? {
        var wid: UInt32 = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        return Int(wid)
    }

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

    // Presses the window's close button; closing has no window-level AX
    // action of its own.
    static func close(_ element: AXUIElement) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(value as! AXUIElement, kAXPressAction as CFString)
    }
}
