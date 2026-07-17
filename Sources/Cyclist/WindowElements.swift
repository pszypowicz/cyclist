import ApplicationServices

// windowID -> AXUIElement, remembered from every snapshot that saw the
// window. An element is a persistent reference into the owning app's AX
// server and stays valid while the window exists - crucially including
// after its Space goes non-visible, where AX refuses to LIST the window
// at all. The repaint nudge needs an element for windows committed via
// CG-only rows (cross-Space targets), and resolving one by enumeration
// mid-transition burns AX timeouts against the busiest possible app;
// this cache turns the lookup into a dictionary hit. Main-confined:
// populated by the snapshot finish paths, read by the nudge, evicted on
// window destroy.
enum WindowElements {
    private static var byID: [Int: AXUIElement] = [:]

    static func note(_ element: AXUIElement, for windowID: Int) {
        byID[windowID] = element
    }

    static func element(for windowID: Int) -> AXUIElement? {
        byID[windowID]
    }

    static func evict(windowID: Int) {
        byID.removeValue(forKey: windowID)
    }
}
