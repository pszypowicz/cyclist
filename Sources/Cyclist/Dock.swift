import AppKit
import ApplicationServices

// Native app activation via the Dock. Space transitions - especially in and
// out of fullscreen Spaces - are Mission Control choreography that only the
// Dock can perform; driving the CGS/SLS Space state directly from outside
// desynchronizes the WindowServer's compositing (old Spaces keep rendering
// underneath, and once that happens even native transitions stop working
// until the Dock is restarted). Pressing the app's Dock item through AX is
// equivalent to the user clicking it: the Dock runs the full native
// transition. Every running regular app has a Dock item.
enum Dock {
    static func pressIcon(named title: String) -> Bool {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return false }
        var queue = children(AXUIElementCreateApplication(dock.processIdentifier))
        while !queue.isEmpty {
            let element = queue.removeFirst()
            if AX.string(element, kAXRoleAttribute) == "AXDockItem",
               AX.string(element, kAXTitleAttribute) == title {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            queue.append(contentsOf: children(element))
        }
        return false
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.map { $0 as! AXUIElement }
    }
}
