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
    // A destroy event can land while a sweep still holding the window's
    // element is in flight; that sweep's finish would re-add the dead
    // entry and no second destroy ever comes. The last few destroyed ids
    // are refused (window ids never recycle within a boot).
    private static var tombstones: [Int] = []

    static func note(_ element: AXUIElement, for windowID: Int) {
        guard !tombstones.contains(windowID) else { return }
        byID[windowID] = element
    }

    static func element(for windowID: Int) -> AXUIElement? {
        byID[windowID]
    }

    static func evict(windowID: Int) {
        byID.removeValue(forKey: windowID)
        tombstones.append(windowID)
        if tombstones.count > 64 {
            tombstones.removeFirst()
        }
    }
}
