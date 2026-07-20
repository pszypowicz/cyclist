import AppKit

// The serial home of all snapshot and title-harvest AX work, so the main
// run loop - which services the event taps - never blocks on an
// unresponsive app. Serial is load-bearing twice over: pendingCommits
// replay in SwitcherController requires snapshot completions to arrive in
// session order, and AppListProvider's title cache is confined to this
// queue. HARD RULE: nothing may ever DispatchQueue.main.sync INTO this
// queue - sweeps begin by main.sync-ing OUT of it to capture inputs, and
// the reverse direction would deadlock.
enum SnapshotQueue {
    static let shared = DispatchQueue(
        label: "cz.szypowi.cyclist.snapshot", qos: .userInteractive)
}

// One app row of the capture: identity plus the mutable
// NSRunningApplication facts frozen at capture time, so the sweep's filter
// and classification cannot disagree about an app that hides mid-sweep.
struct SnapshotApp {
    let app: NSRunningApplication
    let name: String
    let isHidden: Bool
}

// Everything a sweep reads from main-thread-mutated state, captured in one
// main-thread block; the sweep then runs on SnapshotQueue as a pure
// function of this value. Swift collections must never be read off-main
// while their main-thread owner can mutate them - that is memory
// corruption, not staleness.
//
// Captured at the START of the queue work item (via main.sync from the
// worker), not at keypress: the capture block enqueues on main behind the
// previous snapshot's finish/commit, so a sweep always sees post-commit
// recency - the guarantee that makes a quick tap's target rank first when
// the switcher reopens immediately.
struct SnapshotInputs {
    let apps: [SnapshotApp]
    let ranks: [Int: UInt64]
    let aerospace: AeroSpaceClient.WorkspaceSnapshot
    let showHiddenApps: Bool
    let showMinimizedWindows: Bool
    let showWindowsInOtherSpaces: Bool
    let showAppsWithNoWindow: Bool

    // Main thread only. The windows sweep never reads `apps`, so the
    // Cmd+` path skips the enumerate-filter-sort entirely (this block
    // runs under main.sync, where every wasted cycle blocks both main
    // and the snapshot queue). position(of:) is a linear scan; resolve
    // it once per app instead of twice per sort comparison.
    static func capture(mru: MRUTracker, recency: WindowFocusTracker,
                        aerospace: AeroSpaceClient, includeApps: Bool = true) -> SnapshotInputs {
        let apps: [SnapshotApp] = !includeApps ? [] : NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        .map { (position: mru.position(of: $0.processIdentifier), app: $0) }
        .sorted { $0.position < $1.position }
        .map { SnapshotApp(app: $0.app, name: $0.app.localizedName ?? "Unknown", isHidden: $0.app.isHidden) }
        return SnapshotInputs(
            apps: apps,
            ranks: recency.ranksSnapshot(),
            aerospace: aerospace.workspaceSnapshot(),
            showHiddenApps: Settings.showHiddenApps,
            showMinimizedWindows: Settings.showMinimizedWindows,
            showWindowsInOtherSpaces: Settings.showWindowsInOtherSpaces,
            showAppsWithNoWindow: Settings.showAppsWithNoWindow
        )
    }
}

// Most recently focused first, original order as the tiebreak: Swift's
// sort is unstable, and untracked rows (rank 0) must keep their sweep
// order instead of shuffling between snapshots. Shared by both list
// providers.
func sortedByRecency<Element>(_ items: [Element], ranks: [Int: UInt64],
                              windowID: (Element) -> Int?) -> [Element] {
    items.enumerated().sorted { a, b in
        let rankA = windowID(a.element).flatMap { ranks[$0] } ?? 0
        let rankB = windowID(b.element).flatMap { ranks[$0] } ?? 0
        return rankA != rankB ? rankA > rankB : a.offset < b.offset
    }.map(\.element)
}
