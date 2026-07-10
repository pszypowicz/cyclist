import AppKit
import ApplicationServices

enum AppState {
    case normal
    case hidden
    case minimized   // has windows and all of them are minimized
    case otherSpace  // no windows reachable via AX, but owns real windows somewhere
    case noWindows   // running with no real windows anywhere
}

struct AppItem {
    let app: NSRunningApplication
    let name: String
    let state: AppState
    let axWindowCount: Int
    let cgWindowCount: Int
}

// Builds the app list for a switcher session: all regular apps, classified
// and filtered by the hidden/minimized/other-Spaces settings, in MRU order.
//
// Classification without Screen Recording permission:
// - hidden comes straight from NSRunningApplication
// - minimized is derived from the AXMinimized attribute of the app's windows
// - other Spaces is inferred: the AX API cannot see windows in other Spaces,
//   so an app that reports no AX windows but owns CGWindowList windows must
//   have them elsewhere (another Space or a native fullscreen Space)
enum AppListProvider {
    static func snapshot(mru: MRUTracker) -> [AppItem] {
        let cgCounts = cgWindowCounts()
        var items: [AppItem] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isTerminated else { continue }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            let cgCount = cgCounts[app.processIdentifier] ?? 0
            let (state, axCount) = classify(app: app, cgWindowCount: cgCount)
            switch state {
            case .hidden where !Settings.includeHidden: continue
            case .minimized where !Settings.includeMinimized: continue
            case .otherSpace where !Settings.includeOtherSpaces: continue
            default: break
            }
            items.append(AppItem(
                app: app,
                name: app.localizedName ?? "Unknown",
                state: state,
                axWindowCount: axCount,
                cgWindowCount: cgCount
            ))
        }
        items.sort {
            mru.position(of: $0.app.processIdentifier) < mru.position(of: $1.app.processIdentifier)
        }
        return items
    }

    private static func classify(app: NSRunningApplication, cgWindowCount: Int) -> (AppState, Int) {
        let windows = AX.windows(pid: app.processIdentifier)
        if app.isHidden { return (.hidden, windows.count) }
        if windows.isEmpty {
            return cgWindowCount > 0 ? (.otherSpace, 0) : (.noWindows, 0)
        }
        let allMinimized = windows.allSatisfy { AX.bool($0, kAXMinimizedAttribute) == true }
        return (allMinimized ? .minimized : .normal, windows.count)
    }

    private static func cgWindowCounts() -> [pid_t: Int] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var counts: [pid_t: Int] = [:]
        for info in list {
            // Many apps keep invisible bookkeeping windows at layer 0 after
            // their last real window closes (Electron apps especially), so a
            // bare layer check produces phantom "other space" windows. Only
            // count windows that are visible and plausibly user-sized.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 50,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            counts[pid, default: 0] += 1
        }
        return counts
    }
}
