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
        for window in AX.windows(pid: app.processIdentifier) {
            if let subrole = AX.string(window, kAXSubroleAttribute) {
                guard subrole == kAXStandardWindowSubrole as String
                        || subrole == kAXDialogSubrole as String else { continue }
            }
            let minimized = AX.bool(window, kAXMinimizedAttribute) == true
            if minimized && !Settings.includeMinimized { continue }
            let title = AX.string(window, kAXTitleAttribute) ?? ""
            items.append(WindowItem(
                element: window,
                title: title.isEmpty ? (app.localizedName ?? "Untitled") : title,
                isMinimized: minimized,
                windowID: AX.windowID(of: window)
            ))
        }
        return items
    }
}
