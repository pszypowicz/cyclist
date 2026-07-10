import AppKit

// Ctrl+Left/Right and the 3-finger swipe walk the native Spaces of the
// primary display in Mission Control order - user desktops and fullscreen
// Spaces alike - with instant, animation-free jumps. Arriving on a user
// Space focuses its top window, so stepping out of a fullscreen app always
// lands on something concrete instead of leaving the fullscreen app's menu
// bar behind. Workspace systems layered on top of a single Space (AeroSpace
// and friends) keep their own switching bindings; Cyclist deliberately
// stays out of that business.
final class ChainNavigator {
    private let navigator: SpaceNavigator

    init(navigator: SpaceNavigator) {
        self.navigator = navigator
    }

    func navigate(left: Bool) {
        guard let display = Spaces.mainDisplayInfo() else {
            Log.write("chain: no display info")
            return
        }
        guard let currentIndex = display.order.firstIndex(of: display.current) else {
            Log.write("chain: current space \(display.current) not in \(display.order)")
            return
        }
        let targetIndex = currentIndex + (left ? -1 : 1)
        guard display.order.indices.contains(targetIndex) else {
            Log.write("chain: at \(left ? "left" : "right") edge of \(display.order)")
            return
        }
        let target = display.order[targetIndex]
        Log.write("chain: \(left ? "left" : "right") \(display.current) -> \(target)")
        let arrival: (() -> Void)? = display.types[target] == 0
            ? { Self.focusTopUserWindow() }
            : nil
        _ = navigator.begin(to: target, onArrival: arrival)
    }

    // Front-to-back on-screen window list; the first regular-app window is
    // what the user sees on top of the current Space.
    private static func focusTopUserWindow() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 80,
                  let windowID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            else { continue }
            Log.write("chain: focus top window \(windowID) pid \(pid)")
            Spaces.makeKey(pid: pid, windowID: windowID)
            return
        }
    }
}
