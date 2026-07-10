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
    // Titles of windows in other Spaces are unreadable without Screen
    // Recording permission, but most windows were visible at some point:
    // remember titles by window id whenever AX can see them and reuse them
    // for other-Space rows. A title can lag behind a rename that happens
    // while the window is away.
    private static var titleCache: [Int: String] = [:]

    static func cacheTitle(_ title: String, windowID: Int) {
        titleCache[windowID] = title
    }

    // Harvest titles of the frontmost app's now-visible windows. Called on
    // every verified Space arrival, so a window's title is remembered from
    // merely visiting its Space - without this, windows born fullscreen
    // (e.g. a video player) would stay title-less until the switcher was
    // summoned inside their Space at least once.
    static func harvestTitles() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        for window in AX.windows(pid: app.processIdentifier) {
            guard let windowID = AX.windowID(of: window),
                  let title = AX.string(window, kAXTitleAttribute), !title.isEmpty else { continue }
            titleCache[windowID] = title
        }
    }

    static func snapshot(mru: MRUTracker) -> [ListEntry] {
        let (cgWindows, cgTitles) = cgWindowInventory()
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
                let windowID = AX.windowID(of: window)
                if let windowID, !title.isEmpty {
                    titleCache[windowID] = title
                }
                appEntries.append(ListEntry(
                    app: app,
                    appName: name,
                    windowTitle: title.isEmpty ? nil : title,
                    state: state,
                    axWindow: window,
                    spaceID: nil,
                    windowID: windowID
                ))
            }

            // One row per existing non-visible Space that actually contains
            // a window of this app.
            // One row per real window in each non-visible Space. Titles come
            // from CGWindowList when Screen Recording permission is granted
            // (used solely for titles, never captures), else from the cache
            // of titles seen while the window was visible.
            let appWindowIDs = cgWindows[app.processIdentifier] ?? []
            for (space, windowIDs) in otherSpaceWindows {
                let candidates = appWindowIDs.filter { windowIDs.contains($0) }
                guard !candidates.isEmpty else { continue }
                hasAnyWindow = true
                guard Settings.includeOtherSpaces else { continue }
                for windowID in candidates {
                    appEntries.append(ListEntry(
                        app: app,
                        appName: name,
                        windowTitle: cgTitles[windowID] ?? titleCache[windowID],
                        state: .otherSpace,
                        axWindow: nil,
                        spaceID: space,
                        windowID: windowID
                    ))
                }
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

    private static func cgWindowInventory() -> (ids: [pid_t: [Int]], titles: [Int: String]) {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ([:], [:])
        }
        var ids: [pid_t: [Int]] = [:]
        var titles: [Int: String] = [:]
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
            // Populated only when Screen Recording permission is granted.
            if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                titles[windowID] = name
            }
        }
        return (ids, titles)
    }
}
