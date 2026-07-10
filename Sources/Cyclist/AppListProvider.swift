import AppKit
import ApplicationServices

enum EntryState {
    case normal
    case minimized
    case hidden
    case otherSpace  // a real window on a Space that is not currently visible
    case noWindows   // running app with no real windows anywhere
}

// One row of the switcher: a single window of an app, one other-Space
// destination of an app, or a windowless app.
struct ListEntry {
    let app: NSRunningApplication
    let appName: String
    let windowTitle: String?
    let state: EntryState
    let axWindow: AXUIElement?  // set for normal/minimized/hidden rows
    let spaceID: UInt64?        // set for otherSpace rows
    let windowID: Int?          // set for otherSpace rows
}

// Builds the switcher list: every window of every regular app, in app MRU
// order, filtered by the hidden/minimized/other-Spaces/no-windows settings.
//
// Windows in the current Space (plus minimized ones, and windows of hidden
// apps) come from the AX API with their titles. Windows in other Spaces are
// invisible to AX and macOS only reveals their titles to Screen Recording
// holders, so they are represented as one title-less row per Space, resolved
// through the private per-Space window lists.
enum AppListProvider {
    static func snapshot(mru: MRUTracker) -> [ListEntry] {
        let cgWindows = cgWindowIDs()
        let otherSpaceWindows = Spaces.windowsByNonVisibleSpace()
            .sorted { $0.key < $1.key }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            mru.position(of: $0.processIdentifier) < mru.position(of: $1.processIdentifier)
        }

        var entries: [ListEntry] = []
        for app in apps {
            let hidden = app.isHidden
            if hidden && !Settings.includeHidden { continue }
            let name = app.localizedName ?? "Unknown"
            var appEntries: [ListEntry] = []
            var hasAnyWindow = false

            for window in AX.windows(pid: app.processIdentifier) {
                if let subrole = AX.string(window, kAXSubroleAttribute) {
                    guard subrole == kAXStandardWindowSubrole as String
                            || subrole == kAXDialogSubrole as String else { continue }
                }
                hasAnyWindow = true
                let minimized = AX.bool(window, kAXMinimizedAttribute) == true
                let state: EntryState = hidden ? .hidden : (minimized ? .minimized : .normal)
                if state == .minimized && !Settings.includeMinimized { continue }
                let title = AX.string(window, kAXTitleAttribute) ?? ""
                appEntries.append(ListEntry(
                    app: app,
                    appName: name,
                    windowTitle: title.isEmpty ? nil : title,
                    state: state,
                    axWindow: window,
                    spaceID: nil,
                    windowID: AX.windowID(of: window)
                ))
            }

            // One row per existing non-visible Space that actually contains
            // a window of this app.
            let appWindowIDs = cgWindows[app.processIdentifier] ?? []
            for (space, windowIDs) in otherSpaceWindows {
                guard let windowID = appWindowIDs.first(where: { windowIDs.contains($0) }) else { continue }
                hasAnyWindow = true
                guard Settings.includeOtherSpaces else { continue }
                appEntries.append(ListEntry(
                    app: app,
                    appName: name,
                    windowTitle: nil,
                    state: .otherSpace,
                    axWindow: nil,
                    spaceID: space,
                    windowID: windowID
                ))
            }

            if !hasAnyWindow && Settings.includeNoWindows {
                appEntries.append(ListEntry(
                    app: app,
                    appName: name,
                    windowTitle: nil,
                    state: .noWindows,
                    axWindow: nil,
                    spaceID: nil,
                    windowID: nil
                ))
            }
            entries.append(contentsOf: appEntries)
        }
        return entries
    }

    private static func cgWindowIDs() -> [pid_t: [Int]] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var ids: [pid_t: [Int]] = [:]
        for info in list {
            // Layer 0 alone is not enough: apps keep invisible bookkeeping
            // windows there (menu bar sized strips, cached Electron shells,
            // the ~52pt fullscreen toolbar hover strip). Require visible alpha
            // and a plausibly user-sized frame.
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 80,
                  let windowID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            ids[pid, default: []].append(windowID)
        }
        return ids
    }
}
