import AppKit
import ApplicationServices

struct WindowItem {
    let element: AXUIElement?   // nil for windows only the window server can see
    let title: String
    let isMinimized: Bool
    let windowID: Int?
    let spaceID: UInt64?        // non-nil when the window lives in a non-visible Space
    let aerospaceWorkspace: String?  // non-nil when parked in a hidden AeroSpace workspace
}

struct WindowSnapshot {
    let items: [WindowItem]
    // AX listed at least one window for the app. False means the sweep was
    // blind (mid-transition timeout) - NOT that rows were merely filtered -
    // which is what makes the controller's retry worthwhile.
    let sawAXWindows: Bool
}

// Windows of a single app for the same-app cycling session, built on
// SnapshotQueue from SnapshotInputs (the app and its display name are
// resolved at keypress - session identity, not snapshot input). The AX API
// only exposes windows in the current Space plus minimized ones; windows
// in other Spaces (native fullscreen included) come from the window-server
// list with cached titles, the same reachability the app switcher gives
// them, so cycling can jump between an app's windows across Spaces.
enum WindowListProvider {
    static func snapshot(for app: NSRunningApplication, appName: String,
                         inputs: SnapshotInputs) -> WindowSnapshot {
        // AX can stale-list windows of a Space just left; carrying their real
        // Space lets the commit path navigate instead of fronting an app
        // whose window never appears.
        let spaceByWindow = Spaces.nonVisibleSpaceByWindow()
        var items: [WindowItem] = []
        var seenByAX: Set<Int> = []
        var sawAXWindows = false
        for window in AX.qualifiedWindows(pid: app.processIdentifier) {
            sawAXWindows = true
            if let windowID = window.windowID {
                seenByAX.insert(windowID)
            }
            if window.isMinimized && !inputs.includeMinimized { continue }
            if let windowID = window.windowID, let title = window.title {
                AppListProvider.cacheTitle(title, windowID: windowID)
            }
            let space = window.windowID.flatMap { spaceByWindow[$0] }
            items.append(WindowItem(
                element: window.element,
                title: window.title ?? appName,
                isMinimized: window.isMinimized,
                windowID: window.windowID,
                spaceID: space,
                // Native Space membership wins, as in the app switcher: a
                // window in a non-visible native Space needs a real Space
                // transition no matter what AeroSpace thinks of it.
                aerospaceWorkspace: space == nil
                    ? window.windowID.flatMap { inputs.aerospace.hiddenWorkspace(forWindow: $0) }
                    : nil
            ))
        }
        // Windows AX cannot see: parked in non-visible native Spaces.
        // Titles from CGWindowList (Screen Recording holders) or the cache
        // of titles seen while the window was visible.
        if inputs.includeOtherSpaces {
            for window in CGWindows.real([.optionAll, .excludeDesktopElements])
            where window.pid == app.processIdentifier {
                guard let space = spaceByWindow[window.id], !seenByAX.contains(window.id) else { continue }
                items.append(WindowItem(
                    element: nil,
                    title: window.title ?? AppListProvider.cachedTitle(windowID: window.id) ?? appName,
                    isMinimized: false,
                    windowID: window.id,
                    spaceID: space,
                    aerospaceWorkspace: nil
                ))
            }
        }
        AppListProvider.flushTitleCache()
        // Index 0 becomes the current window, so the session's start index
        // (1) is the most recent OTHER window and a quick Cmd+` bounces
        // between the last two.
        return WindowSnapshot(items: sortedByRecency(items, ranks: inputs.ranks, windowID: \.windowID),
                              sawAXWindows: sawAXWindows)
    }
}
