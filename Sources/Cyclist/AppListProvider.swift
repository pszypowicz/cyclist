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
    // Titles of windows in other Spaces are mostly unreadable: CG names need
    // Screen Recording permission and are empty anyway for windows like
    // Safari's video fullscreen, and AX only reads titles of windows whose
    // Space is current. So remember titles by window id whenever the AX API
    // can see them and reuse them for other-Space rows. The cache persists
    // across app restarts but not reboots (window ids recycle); a title can
    // lag behind a rename that happens while the window is away.
    private static let cacheStoreKey = "titleCacheStore"
    private static let cacheBootKey = "titleCacheBootTime"

    private static var titleCache: [Int: String] = loadCache()

    static func cacheTitle(_ title: String, windowID: Int) {
        guard titleCache[windowID] != title else { return }
        titleCache[windowID] = title
        persistCache()
    }

    // Harvest titles of all windows on the current Space (plus the frontmost
    // app's). Called on every verified Space arrival, so a window's title is
    // remembered from merely visiting its Space - without this, windows born
    // fullscreen (e.g. a video player) would stay title-less until the
    // switcher was summoned inside their Space at least once.
    static func harvestTitles() {
        var pids: Set<pid_t> = []
        if let display = Spaces.mainDisplayInfo() {
            let currentWindows = Spaces.windowIDs(inSpace: display.current)
            for window in CGWindows.real([.optionAll, .excludeDesktopElements])
            where currentWindows.contains(window.id) {
                pids.insert(window.pid)
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            pids.insert(front)
        }
        var changed = false
        for pid in pids {
            guard NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
            for window in AX.windows(pid: pid) {
                guard let windowID = AX.windowID(of: window),
                      let title = AX.string(window, kAXTitleAttribute), !title.isEmpty,
                      titleCache[windowID] != title else { continue }
                titleCache[windowID] = title
                changed = true
            }
        }
        if changed {
            persistCache()
        }
    }

    private static func bootTime() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Double(tv.tv_sec)
    }

    private static func loadCache() -> [Int: String] {
        let defaults = UserDefaults.standard
        guard defaults.double(forKey: cacheBootKey) == bootTime(),
              let stored = defaults.dictionary(forKey: cacheStoreKey) as? [String: String]
        else { return [:] }
        var cache: [Int: String] = [:]
        for (key, title) in stored {
            if let windowID = Int(key) {
                cache[windowID] = title
            }
        }
        return cache
    }

    private static func persistCache() {
        let defaults = UserDefaults.standard
        defaults.set(bootTime(), forKey: cacheBootKey)
        defaults.set(
            Dictionary(uniqueKeysWithValues: titleCache.map { (String($0.key), $0.value) }),
            forKey: cacheStoreKey
        )
    }

    static func snapshot(mru: MRUTracker) -> [ListEntry] {
        var cgWindows: [pid_t: [Int]] = [:]
        var cgTitles: [Int: String] = [:]
        for window in CGWindows.real([.optionAll, .excludeDesktopElements]) {
            cgWindows[window.pid, default: []].append(window.id)
            cgTitles[window.id] = window.title
        }
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
                    cacheTitle(title, windowID: windowID)
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

}
