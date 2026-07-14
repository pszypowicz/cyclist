import AppKit
import ApplicationServices

struct WindowItem {
    let element: AXUIElement
    let title: String
    let isMinimized: Bool
    let windowID: Int?
    let spaceID: UInt64?  // non-nil when the window lives in a non-visible Space
}

// Windows of a single app for the same-app cycling session. The AX API only
// exposes windows in the current Space plus minimized ones; windows parked in
// other Spaces are invisible here.
enum WindowListProvider {
    static func snapshot(for app: NSRunningApplication, recency: WindowFocusTracker) -> [WindowItem] {
        // AX can stale-list windows of a Space just left; carrying their real
        // Space lets the commit path navigate instead of fronting an app
        // whose window never appears.
        var spaceByWindow: [Int: UInt64] = [:]
        for (space, windowIDs) in Spaces.windowsByNonVisibleSpace() {
            for id in windowIDs { spaceByWindow[id] = space }
        }
        var items: [WindowItem] = []
        for window in AX.qualifiedWindows(pid: app.processIdentifier) {
            if window.isMinimized && !Settings.includeMinimized { continue }
            if let windowID = window.windowID, let title = window.title {
                AppListProvider.cacheTitle(title, windowID: windowID)
            }
            items.append(WindowItem(
                element: window.element,
                title: window.title ?? (app.localizedName ?? "Untitled"),
                isMinimized: window.isMinimized,
                windowID: window.windowID,
                spaceID: window.windowID.flatMap { spaceByWindow[$0] }
            ))
        }
        AppListProvider.flushTitleCache()
        // Most recently focused first: index 0 becomes the current window,
        // so the session's start index (1) is the most recent OTHER window
        // and a quick Cmd+` bounces between the last two. Index tiebreak
        // keeps AX order for untracked windows (Swift's sort is unstable).
        return items.enumerated().sorted { a, b in
            let rankA = recency.rank(of: a.element.windowID)
            let rankB = recency.rank(of: b.element.windowID)
            return rankA != rankB ? rankA > rankB : a.offset < b.offset
        }.map(\.element)
    }
}
