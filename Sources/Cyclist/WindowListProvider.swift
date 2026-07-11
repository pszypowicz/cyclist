import AppKit
import ApplicationServices

struct WindowItem {
    let element: AXUIElement
    let title: String
    let isMinimized: Bool
    let windowID: Int?
}

// Windows of a single app for the same-app cycling session. The AX API only
// exposes windows in the current Space plus minimized ones; windows parked in
// other Spaces are invisible here.
enum WindowListProvider {
    static func snapshot(for app: NSRunningApplication) -> [WindowItem] {
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
                windowID: window.windowID
            ))
        }
        AppListProvider.flushTitleCache()
        return items
    }
}
