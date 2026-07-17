import ApplicationServices
import Foundation

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
    // and CG window id, at ONE batched attribute IPC per window (plus the
    // window-id call) instead of four. A window whose subrole is unreadable
    // passes the filter (matching apps that report no subrole at all); an
    // unreadable ROLE drops the window - Finder reports the desktop as a
    // full-screen AXScrollArea, and only real AXWindow elements count.
    static func qualifiedWindows(pid: pid_t) -> [AXWindowInfo] {
        rawWindows(pid: pid).compactMap { window in
            guard let slots = batch(window, [kAXRoleAttribute, kAXSubroleAttribute,
                                             kAXTitleAttribute, kAXMinimizedAttribute]) else { return nil }
            guard slots[0] as? String == kAXWindowRole as String else { return nil }
            if let subrole = slots[1] as? String {
                guard subrole == kAXStandardWindowSubrole as String
                        || subrole == kAXDialogSubrole as String else { return nil }
            }
            let title = slots[2] as? String
            return AXWindowInfo(
                element: window,
                title: (title?.isEmpty == false) ? title : nil,
                isMinimized: (slots[3] as? Bool) == true,
                windowID: windowID(of: window)
            )
        }
    }

    // Window id and title of every real window, for the title harvest: one
    // batched IPC per window instead of separate role and title reads.
    static func windowTitles(pid: pid_t) -> [(windowID: Int, title: String)] {
        rawWindows(pid: pid).compactMap { window in
            guard let slots = batch(window, [kAXRoleAttribute, kAXTitleAttribute]),
                  slots[0] as? String == kAXWindowRole as String,
                  let title = slots[1] as? String, !title.isEmpty,
                  let windowID = windowID(of: window) else { return nil }
            return (windowID, title)
        }
    }

    // The app's window elements with no per-element attribute reads; role
    // filtering rides the callers' batched copies.
    private static func rawWindows(pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else {
            return []
        }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }

    // One round trip for several attributes. A slot whose attribute could
    // not be read arrives as an AXValue error placeholder, which fails the
    // callers' typed casts; a message-level failure (timeout, dead element)
    // returns nil and the caller drops the element - matching the old
    // per-attribute path, where the first failed read dropped it.
    private static func batch(_ element: AXUIElement, _ attributes: [String]) -> [AnyObject]? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
                element, attributes as CFArray, AXCopyMultipleAttributeOptions(), &values) == .success,
              let slots = values as? [AnyObject], slots.count == attributes.count else { return nil }
        return slots
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

    static func position(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    // Forces a window to repaint after a cross-Space arrival. On macOS 26 an
    // arrived window's backing store can be purged - the screen shows bare
    // wallpaper though every bookkeeping signal is healthy - and only a real
    // geometry change makes the app redraw; activating or raising the window
    // does not (the WindowServer holds the empty backing, and the compositor
    // never re-requests content). A 1px move that returns to the exact origin
    // is that change, imperceptible in practice. SLSMoveWindow cannot do this
    // from outside the owning process, so it goes through AXPosition - the
    // same path AeroSpace heals with when it re-tiles. The restore is
    // deferred one turn so the move commits as a distinct change rather than
    // coalescing to a no-op.
    //
    // One shot is not enough under rapid bouncing (measured ~17% of fast
    // arrivals still wallpaper at +0.6s): mid-arrival the app can blow the
    // AX timeout - the enumeration returns nothing and the nudge silently
    // no-ops - or the nudge lands before the compositor re-requests
    // content. So: use the commit's own element when the row carried one,
    // retry a failed resolution briefly, and always repeat one delayed
    // nudge after a successful one.
    static func repaintNudge(pid: pid_t, windowID: Int, element: AXUIElement? = nil, attempt: Int = 0) {
        guard attempt < 4 else { return }
        // Resolve by window id over the raw element list - no role reads.
        // The lookup runs against an app mid-compositing, where every AX
        // message risks the full timeout; the blank-to-content beat the
        // user sees is this resolution plus the retry ladder, so it must
        // be as few messages as possible and the retries tight.
        guard let resolved = element
                ?? rawWindows(pid: pid).first(where: { self.windowID(of: $0) == windowID }),
              let origin = position(resolved) else {
            // Re-resolve from scratch next time: a passed element that
            // refuses a position read may be stale.
            Log.debug("nudge: wid=\(windowID) attempt=\(attempt) unresolved")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                repaintNudge(pid: pid, windowID: windowID, attempt: attempt + 1)
            }
            return
        }
        Log.debug("nudge: wid=\(windowID) attempt=\(attempt) applied")
        setPosition(resolved, CGPoint(x: origin.x + 1, y: origin.y))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            setPosition(resolved, origin)
            if attempt == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    repaintNudge(pid: pid, windowID: windowID, element: resolved, attempt: 3)
                }
            }
        }
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
