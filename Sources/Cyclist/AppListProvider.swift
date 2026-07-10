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
    // Space holding the app's window when state is otherSpace.
    let otherSpaceID: UInt64?
}

// Builds the app list for a switcher session: all regular apps, classified
// and filtered by the hidden/minimized/other-Spaces settings, in MRU order.
//
// Classification without Screen Recording permission:
// - hidden comes straight from NSRunningApplication
// - minimized is derived from the AXMinimized attribute of the app's windows
// - other Spaces is inferred: the AX API cannot see windows in other Spaces,
//   so an app with no AX windows that owns a window assigned to a Space that
//   is not currently visible has that window elsewhere (another Space or a
//   native fullscreen Space). Space membership has to come from private CGS
//   calls; apps also keep phantom windows alive after their last real window
//   closes, and those are either Space-less or sit on the visible Space where
//   AX would have seen a real one.
enum AppListProvider {
    static func snapshot(mru: MRUTracker) -> [AppItem] {
        let cgWindows = cgWindowIDs()
        let visibleSpaces = Spaces.visibleSpaceIDs()
        var items: [AppItem] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isTerminated else { continue }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            let windowIDs = cgWindows[app.processIdentifier] ?? []
            let (state, axCount, otherSpaceID) = classify(app: app, windowIDs: windowIDs, visibleSpaces: visibleSpaces)
            switch state {
            case .hidden where !Settings.includeHidden: continue
            case .minimized where !Settings.includeMinimized: continue
            case .otherSpace where !Settings.includeOtherSpaces: continue
            case .noWindows where !Settings.includeNoWindows: continue
            default: break
            }
            items.append(AppItem(
                app: app,
                name: app.localizedName ?? "Unknown",
                state: state,
                axWindowCount: axCount,
                cgWindowCount: windowIDs.count,
                otherSpaceID: otherSpaceID
            ))
        }
        items.sort {
            mru.position(of: $0.app.processIdentifier) < mru.position(of: $1.app.processIdentifier)
        }
        return items
    }

    private static func classify(
        app: NSRunningApplication,
        windowIDs: [Int],
        visibleSpaces: Set<UInt64>
    ) -> (AppState, Int, UInt64?) {
        let windows = AX.windows(pid: app.processIdentifier)
        if app.isHidden { return (.hidden, windows.count, nil) }
        if windows.isEmpty {
            // A window on a Space that is not currently visible is genuinely
            // elsewhere. Space-less windows and windows sitting on the visible
            // Space (where AX would have seen a real one) are phantoms left
            // behind by closed windows.
            for id in windowIDs {
                let spaces = Spaces.spaceIDs(ofWindow: id)
                if let space = spaces.first, spaces.isDisjoint(with: visibleSpaces) {
                    return (.otherSpace, 0, space)
                }
            }
            return (.noWindows, 0, nil)
        }
        let allMinimized = windows.allSatisfy { AX.bool($0, kAXMinimizedAttribute) == true }
        return (allMinimized ? .minimized : .normal, windows.count, nil)
    }

    private static func cgWindowIDs() -> [pid_t: [Int]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var ids: [pid_t: [Int]] = [:]
        for info in list {
            // Layer 0 alone is not enough: apps keep invisible bookkeeping
            // windows there (menu bar sized strips, cached Electron shells).
            // Require visible alpha and a plausibly user-sized frame.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 50,
                  let windowID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            ids[pid, default: []].append(windowID)
        }
        return ids
    }
}
