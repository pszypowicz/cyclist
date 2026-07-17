import AppKit
import ApplicationServices

enum EntryState {
    case normal
    case minimized
    case hidden
    case otherSpace       // a real window on a Space that is not currently visible
    case hiddenWorkspace  // parked off-screen by AeroSpace in a non-visible workspace
    case noWindows        // running app with no real windows anywhere
}

// One row of the switcher: a single window of an app, one other-Space
// destination of an app, or a windowless app.
struct ListEntry {
    let app: NSRunningApplication
    let appName: String
    let windowTitle: String?
    let state: EntryState
    let axWindow: AXUIElement?  // set whenever AX exposes the window, any state
    let spaceID: UInt64?        // set for otherSpace rows with a known Space
    let windowID: Int?          // set for every real-window row AX can resolve
    let aerospaceWorkspace: String?  // set for hiddenWorkspace rows
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
    private static var cacheDirty = false

    // The single mutation point of the cache. Persistence is deferred to
    // flushTitleCache so a snapshot or harvest writes UserDefaults at most
    // once instead of re-serializing the whole cache per new title.
    static func cacheTitle(_ title: String, windowID: Int) {
        guard titleCache[windowID] != title else { return }
        titleCache[windowID] = title
        cacheDirty = true
    }

    static func flushTitleCache() {
        guard cacheDirty else { return }
        cacheDirty = false
        persistCache()
    }

    // Windows close constantly across a weeks-long session; without
    // eviction the cache (and its persisted copy) grows one entry per
    // window ever titled. Persistence rides the next flush - a destroy
    // burst must not cost one UserDefaults write each.
    static func evictTitle(windowID: Int) {
        guard titleCache.removeValue(forKey: windowID) != nil else { return }
        cacheDirty = true
    }

    static func cachedTitle(windowID: Int) -> String? {
        titleCache[windowID]
    }

    // Harvest titles of all windows on the current Space (plus the frontmost
    // app's). Called on every verified Space arrival, so a window's title is
    // remembered from merely visiting its Space - without this, windows born
    // fullscreen (e.g. a video player) would stay title-less until the
    // switcher was summoned inside their Space at least once.
    static func harvestTitles() {
        var pids: Set<pid_t> = []
        if let display = Spaces.activeDisplayInfo() {
            let currentWindows = Spaces.windowIDs(inSpace: display.current)
            for window in CGWindows.real([.optionAll, .excludeDesktopElements])
            where currentWindows.contains(window.id) {
                pids.insert(window.pid)
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            pids.insert(front)
        }
        harvestTitles(pids: pids)
    }

    // AX title sweep for the given apps only. Cheap enough for hot callers
    // (a single app on activation); the full-Space pid discovery above is
    // reserved for Space arrivals.
    static func harvestTitles(pids: Set<pid_t>) {
        for pid in pids {
            guard NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
            for window in AX.windows(pid: pid) {
                guard let windowID = AX.windowID(of: window),
                      let title = AX.string(window, kAXTitleAttribute), !title.isEmpty else { continue }
                cacheTitle(title, windowID: windowID)
            }
        }
        flushTitleCache()
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

    // The client is safe to consult in any state: inactive means an empty
    // cache, so hiddenWorkspace lookups return nil and rows classify
    // exactly as without the integration.
    static func snapshot(mru: MRUTracker, recency: WindowFocusTracker, aerospace: AeroSpaceClient) -> [ListEntry] {
        var cgWindows: [pid_t: [Int]] = [:]
        var cgTitles: [Int: String] = [:]
        for window in CGWindows.real([.optionAll, .excludeDesktopElements]) {
            cgWindows[window.pid, default: []].append(window.id)
            cgTitles[window.id] = window.title
        }
        let otherSpaceWindows = Spaces.windowsByNonVisibleSpace()
            .sorted { $0.key < $1.key }
        var spaceByWindow: [Int: UInt64] = [:]
        for (space, windowIDs) in otherSpaceWindows {
            for id in windowIDs { spaceByWindow[id] = space }
        }

        // position(of:) is a linear scan; resolve it once per app instead
        // of twice per sort comparison.
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        .map { (position: mru.position(of: $0.processIdentifier), app: $0) }
        .sorted { $0.position < $1.position }
        .map(\.app)

        var entries: [ListEntry] = []
        for app in apps {
            let hidden = app.isHidden
            if hidden && !Settings.includeHidden { continue }
            let name = app.localizedName ?? "Unknown"
            var appEntries: [ListEntry] = []
            var hasAnyWindow = false
            var hasOtherSpaceWindows = false

            // Space membership is classified here, not at commit time: after
            // rapid switching AX can still list windows of the Space just
            // left, and minimized/hidden windows stay AX-visible while their
            // Space is not. Such windows are real otherSpace rows - shown
            // truthfully and committed with a Space transition.
            var seenByAX: Set<Int> = []
            for window in AX.qualifiedWindows(pid: app.processIdentifier) {
                hasAnyWindow = true
                if let windowID = window.windowID {
                    seenByAX.insert(windowID)
                }
                if window.isMinimized && !Settings.includeMinimized { continue }
                if let windowID = window.windowID, let title = window.title {
                    cacheTitle(title, windowID: windowID)
                }
                let space = window.windowID.flatMap { spaceByWindow[$0] }
                // AeroSpace parks hidden-workspace windows off-screen on the
                // current native Space, so AX lists them like ordinary
                // windows. Native Space membership wins when both apply: a
                // window in a non-visible native Space needs a real Space
                // transition no matter what AeroSpace thinks of it.
                let workspace = space == nil
                    ? window.windowID.flatMap { aerospace.hiddenWorkspace(forWindow: $0) }
                    : nil
                if space != nil || workspace != nil {
                    hasOtherSpaceWindows = true
                    if !Settings.includeOtherSpaces { continue }
                }
                let state: EntryState = space != nil ? .otherSpace
                    : workspace != nil ? .hiddenWorkspace
                    : hidden ? .hidden : (window.isMinimized ? .minimized : .normal)
                appEntries.append(ListEntry(
                    app: app,
                    appName: name,
                    windowTitle: window.title
                        ?? window.windowID.flatMap { cgTitles[$0] ?? titleCache[$0] },
                    state: state,
                    axWindow: window.element,
                    spaceID: space,
                    windowID: window.windowID,
                    aerospaceWorkspace: workspace
                ))
            }

            // One row per real window in each non-visible Space. Titles come
            // from CGWindowList when Screen Recording permission is granted
            // (used solely for titles, never captures), else from the cache
            // of titles seen while the window was visible.
            // Windows already emitted (or deliberately filtered) by the AX
            // loop are skipped so a minimized/hidden window parked in a
            // non-visible Space cannot produce a second row.
            let appWindowIDs = cgWindows[app.processIdentifier] ?? []
            for (space, windowIDs) in otherSpaceWindows {
                let candidates = appWindowIDs.filter {
                    windowIDs.contains($0) && !seenByAX.contains($0)
                }
                guard !candidates.isEmpty else { continue }
                hasAnyWindow = true
                hasOtherSpaceWindows = true
                guard Settings.includeOtherSpaces else { continue }
                for windowID in candidates {
                    appEntries.append(ListEntry(
                        app: app,
                        appName: name,
                        windowTitle: cgTitles[windowID] ?? titleCache[windowID],
                        state: .otherSpace,
                        axWindow: nil,
                        spaceID: space,
                        windowID: windowID,
                        aerospaceWorkspace: nil
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
                    windowID: nil,
                    aerospaceWorkspace: nil
                ))
            }

            // With other-Space rows filtered out, an app whose windows all
            // live in other Spaces would otherwise vanish from the switcher
            // entirely (it is not windowless, so the fallback above never
            // applies). Keep it reachable with one handle-less row; commit
            // summons it with Dock-reopen semantics.
            if appEntries.isEmpty && hasOtherSpaceWindows {
                appEntries.append(ListEntry(
                    app: app,
                    appName: name,
                    windowTitle: nil,
                    state: .otherSpace,
                    axWindow: nil,
                    spaceID: nil,
                    windowID: nil,
                    aerospaceWorkspace: nil
                ))
            }
            // Most recently focused window first within the app. Swift's
            // sort is not stable, so the original index is the tiebreak:
            // untracked windows (rank 0, including the handle-less fallback
            // rows) keep their AX-then-CG order instead of shuffling
            // between snapshots.
            let ranked = appEntries.enumerated().sorted { a, b in
                let rankA = recency.rank(of: a.element.windowID)
                let rankB = recency.rank(of: b.element.windowID)
                return rankA != rankB ? rankA > rankB : a.offset < b.offset
            }
            entries.append(contentsOf: ranked.map(\.element))
        }
        flushTitleCache()
        return entries
    }

}
