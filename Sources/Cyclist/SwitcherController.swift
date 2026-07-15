import AppKit

// State machine for a switcher session: Cmd+Tab starts an app session,
// Cmd+` starts a window session for the frontmost app. While Cmd is held,
// Tab/backtick advance (Shift reverses), Esc cancels, and releasing Cmd
// commits the current selection.
final class SwitcherController {
    private let tap = EventTap()
    private let mru: MRUTracker
    private let recency: WindowFocusTracker
    private let aerospace: AeroSpaceClient
    private let panel = SwitcherPanel()
    private let navigator: SpaceNavigator
    private lazy var chain = ChainNavigator(navigator: navigator, aerospace: aerospace)

    private enum Session {
        // Snapshot still building off the tap callback. `presses` records
        // each Tab/backtick press as its Shift state (never empty) so the
        // completion replays them through the same start-index and step
        // logic a live session uses.
        case pendingApps(presses: [Bool])
        case pendingWindows(NSRunningApplication, presses: [Bool])
        case apps([ListEntry], index: Int)
        case windows(NSRunningApplication, [WindowItem], index: Int)
    }
    private var session: Session?
    // Guards pending completions: a snapshot that resolves after its session
    // was cancelled or superseded must not apply.
    private var snapshotGeneration = 0
    // Pending sessions whose Cmd was already released: they commit when
    // their snapshot arrives. Kept outside `session` so the release keeps
    // its usual meaning - the session is over, Esc passes through again,
    // and the next press starts a fresh session instead of folding into a
    // finished one.
    private var pendingCommits: [(generation: Int, session: Session)] = []
    private var showPanelWork: DispatchWorkItem?
    // Invalidates async focus fallbacks (an AeroSpace focus command can
    // fail up to its timeout later) once a newer activation happened;
    // native arrivals are covered by navigator.cancel() instead.
    private var activationGeneration = 0
    // NSWorkspace's frontmost app lags a makeKey/AeroSpace activation by
    // ~0.1-1s. A press inside that window would classify rows against the
    // app just left: a quick Cmd+Tab re-commits the very window the user
    // is on, and Cmd+` lists the wrong app's windows. Right after our own
    // commit, we are the fresher source of truth.
    private var lastCommit: (app: NSRunningApplication, at: Date)?

    // Fired when the key tap dies (e.g. Accessibility revoked at runtime);
    // the owner polls for the grant and calls start() to rebuild.
    var onTapInvalidated: (() -> Void)?

    private let tabKey: Int64 = 48
    private let graveKey: Int64 = 50
    private let escapeKey: Int64 = 53
    private let leftArrowKey: Int64 = 123
    private let rightArrowKey: Int64 = 124

    init(mru: MRUTracker, recency: WindowFocusTracker, aerospace: AeroSpaceClient, events: WindowServerEvents) {
        self.mru = mru
        self.recency = recency
        self.aerospace = aerospace
        self.navigator = SpaceNavigator(events: events)
        tap.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        tap.onFlagsChanged = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        tap.onInvalidated = { [weak self] in
            self?.onTapInvalidated?()
        }
    }

    func start() -> Bool {
        tap.start()
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let backward = flags.contains(.maskShift)
        let control = flags.contains(.maskControl)
        let alternate = flags.contains(.maskAlternate)
        let otherModifiers = control || alternate
        let controlOnly = control && !command && !backward && !alternate

        switch keyCode {
        case tabKey where command && !otherModifiers:
            advanceApps(backward: backward)
            return true
        case graveKey where command && !otherModifiers:
            advanceWindows(backward: backward)
            return true
        case escapeKey where session != nil:
            cancel()
            return true
        case leftArrowKey where controlOnly, rightArrowKey where controlOnly:
            // Space navigation, handled off the tap callback so nothing can
            // stall event delivery.
            let left = keyCode == leftArrowKey
            DispatchQueue.main.async { [weak self] in self?.chain.navigate(left: left) }
            return true
        default:
            return false
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        guard let session, !event.flags.contains(.maskCommand) else { return }
        switch session {
        case .pendingApps, .pendingWindows:
            pendingCommits.append((snapshotGeneration, session))
            self.session = nil
        case .apps, .windows:
            commit()
        }
    }

    private func advanceApps(backward: Bool) {
        switch session {
        case .apps(let items, let index):
            let next = step(index, count: items.count, backward: backward)
            session = .apps(items, index: next)
            panel.select(index: next)
        case .pendingApps(let presses):
            // A press while the snapshot builds advances the pending
            // selection.
            session = .pendingApps(presses: presses + [backward])
        case .windows, .pendingWindows:
            break
        case nil:
            // The snapshot's AX sweep can take long enough to get the tap
            // disabled (and stall all keyboard input behind the callback),
            // so it runs after the callback returns; presses and the Cmd
            // release accumulate on the pending session meanwhile. Snapshots
            // are dispatched in session order, so a fresh session started
            // right after a quick tap resolves after the tap's commit.
            session = .pendingApps(presses: [backward])
            snapshotGeneration += 1
            let generation = snapshotGeneration
            // Freshen the workspace cache for commit time and the next
            // session; the snapshot below reads whatever is cached now.
            aerospace.refresh()
            aerospace.kick()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.finishAppsSnapshot(
                    AppListProvider.snapshot(mru: self.mru, recency: self.recency, aerospace: self.aerospace),
                    generation: generation)
            }
        }
    }

    private func advanceWindows(backward: Bool) {
        switch session {
        case .windows(let app, let items, let index):
            let next = step(index, count: items.count, backward: backward)
            session = .windows(app, items, index: next)
            panel.select(index: next)
        case .pendingWindows(let app, let presses):
            session = .pendingWindows(app, presses: presses + [backward])
        case .apps, .pendingApps:
            break
        case nil:
            guard let app = frontmostForSessions() else { return }
            session = .pendingWindows(app, presses: [backward])
            snapshotGeneration += 1
            let generation = snapshotGeneration
            DispatchQueue.main.async { [weak self] in
                self?.buildWindowsSnapshot(for: app, generation: generation, attempt: 0)
            }
        }
    }

    private func finishAppsSnapshot(_ items: [ListEntry], generation: Int) {
        // Cmd already released: a quick tap commits straight from here,
        // never showing the panel.
        if let pendingIndex = pendingCommits.firstIndex(where: { $0.generation == generation }) {
            let pending = pendingCommits.remove(at: pendingIndex)
            guard case .pendingApps(let presses) = pending.session else { return }
            guard !items.isEmpty else {
                Log.write("apps snapshot empty; consumed Cmd+Tab dropped")
                return
            }
            activate(items[replay(presses, count: items.count,
                                  initial: initialAppsIndex(items: items, backward: presses[0]))])
            return
        }
        guard generation == snapshotGeneration,
              case .pendingApps(let presses) = session else { return }
        guard !items.isEmpty else {
            Log.write("apps snapshot empty; consumed Cmd+Tab dropped")
            session = nil
            return
        }
        let index = replay(presses, count: items.count,
                           initial: initialAppsIndex(items: items, backward: presses[0]))
        session = .apps(items, index: index)
        presentPanel(
            rows: items.map {
                SwitcherRow(icon: $0.app.icon, title: $0.appName, subtitle: $0.windowTitle,
                            annotation: annotation(for: $0))
            },
            selected: index
        )
    }

    // Mid Space-transition an app can blow the 0.05s AX messaging timeout
    // and list no current-Space windows at all; a session resolved against
    // such a CG-only list commits an other-Space row and mis-navigates
    // (observed as back-to-back jumps to the same Space when Cmd+` is
    // pressed rapidly across Spaces). The frontmost app always has at
    // least one current-Space window, so an AX-empty list is implausible:
    // retry once shortly; the session stays pending and presses accumulate.
    private func buildWindowsSnapshot(for app: NSRunningApplication, generation: Int, attempt: Int) {
        let items = WindowListProvider.snapshot(for: app, recency: recency, aerospace: aerospace)
        if attempt == 0, !items.contains(where: { $0.element != nil }) {
            Log.write("windows snapshot: no AX rows for pid=\(app.processIdentifier); retrying")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.buildWindowsSnapshot(for: app, generation: generation, attempt: 1)
            }
            return
        }
        finishWindowsSnapshot(items, generation: generation)
    }

    private func finishWindowsSnapshot(_ items: [WindowItem], generation: Int) {
        if let pendingIndex = pendingCommits.firstIndex(where: { $0.generation == generation }) {
            let pending = pendingCommits.remove(at: pendingIndex)
            guard case .pendingWindows(let app, let presses) = pending.session else { return }
            guard !items.isEmpty else {
                Log.write("window snapshot empty; consumed Cmd+` dropped")
                return
            }
            let item = items[replay(presses, count: items.count,
                                    initial: startIndex(count: items.count, backward: presses[0]))]
            focus(app: app, element: item.element, windowID: item.windowID,
                  spaceID: item.spaceID, workspace: item.aerospaceWorkspace)
            return
        }
        guard generation == snapshotGeneration,
              case .pendingWindows(let app, let presses) = session else { return }
        guard !items.isEmpty else {
            Log.write("window snapshot empty; consumed Cmd+` dropped")
            session = nil
            return
        }
        let index = replay(presses, count: items.count,
                           initial: startIndex(count: items.count, backward: presses[0]))
        session = .windows(app, items, index: index)
        presentPanel(
            rows: items.map {
                SwitcherRow(icon: app.icon, title: $0.title, subtitle: nil,
                            annotation: annotation(for: $0))
            },
            selected: index
        )
    }

    // The first press picked the start index; each further press steps.
    private func replay(_ presses: [Bool], count: Int, initial: Int) -> Int {
        presses.dropFirst().reduce(initial) { index, backward in
            step(index, count: count, backward: backward)
        }
    }

    private func frontmostForSessions() -> NSRunningApplication? {
        if let lastCommit, Date().timeIntervalSince(lastCommit.at) < 1.5 {
            return lastCommit.app
        }
        return NSWorkspace.shared.frontmostApplication
    }

    // A quick tap goes to the previously used WINDOW, wherever it lives:
    // after deliberately visiting two windows of one app, the sibling
    // window is the suggestion, not another app - and after coming from
    // another app, that app's window outranks the stale sibling. One rule
    // covers both: the best-ranked window that is not the one holding
    // focus. Rows without ranks fall back to the previous-app heuristic.
    private func initialAppsIndex(items: [ListEntry], backward: Bool) -> Int {
        if backward { return items.count - 1 }
        let current = recency.latestWindowID
        var best: (index: Int, rank: UInt64)?
        for (index, item) in items.enumerated() {
            guard let windowID = item.windowID, windowID != current else { continue }
            let rank = recency.rank(of: windowID)
            if rank > 0, rank > (best?.rank ?? 0) {
                best = (index, rank)
            }
        }
        if let best {
            return best.index
        }
        let front = frontmostForSessions()?.processIdentifier
        let firstOtherApp = items.firstIndex { $0.app.processIdentifier != front }
        return firstOtherApp ?? (items.count > 1 ? 1 : 0)
    }

    private func startIndex(count: Int, backward: Bool) -> Int {
        guard count > 1 else { return 0 }
        return backward ? count - 1 : 1
    }

    private func step(_ index: Int, count: Int, backward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return (index + (backward ? count - 1 : 1)) % count
    }

    private func annotation(for entry: ListEntry) -> String? {
        switch entry.state {
        case .normal: return nil
        case .hidden: return "hidden"
        case .minimized: return "minimized"
        case .otherSpace: return "other space"
        case .hiddenWorkspace: return "workspace \(entry.aerospaceWorkspace ?? "?")"
        case .noWindows: return "no windows"
        }
    }

    private func annotation(for item: WindowItem) -> String? {
        if item.spaceID != nil { return "other space" }
        if let workspace = item.aerospaceWorkspace { return "workspace \(workspace)" }
        return item.isMinimized ? "minimized" : nil
    }

    // Delay showing the panel slightly so a quick Cmd+Tab tap switches to the
    // previous app without a visual flash.
    private func presentPanel(rows: [SwitcherRow], selected: Int) {
        panel.setRows(rows, selected: selected)
        let work = DispatchWorkItem { [weak self] in self?.panel.show() }
        showPanelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func dismissPanel() {
        showPanelWork?.cancel()
        showPanelWork = nil
        panel.hide()
    }

    private func cancel() {
        session = nil
        dismissPanel()
    }

    private func commit() {
        guard let session else { return }
        switch session {
        case .pendingApps, .pendingWindows:
            // A pending session commits from its snapshot completion.
            return
        case .apps(let items, let index):
            self.session = nil
            dismissPanel()
            activate(items[index])
        case .windows(let app, let items, let index):
            self.session = nil
            dismissPanel()
            let item = items[index]
            focus(app: app, element: item.element, windowID: item.windowID,
                  spaceID: item.spaceID, workspace: item.aerospaceWorkspace)
        }
    }

    private func activate(_ entry: ListEntry) {
        let app = entry.app
        Log.write("activate: app=\(entry.appName) state=\(entry.state)"
            + " windowID=\(entry.windowID.map(String.init) ?? "-")"
            + " spaceID=\(entry.spaceID.map(String.init) ?? "-")"
            + " from=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        // Plain activation does nothing visible for an app with no windows,
        // and a row without any window handle (an other-Space app shown only
        // as a reachability fallback) has nothing to focus or navigate to.
        // Launching again is Dock-click semantics: the app gets a reopen
        // event and brings its own windows along.
        if entry.state == .noWindows || (entry.axWindow == nil && entry.windowID == nil),
           let url = app.bundleURL {
            navigator.cancel()
            lastCommit = (app, Date())
            recency.expectActivation(of: app)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        focus(app: app, element: entry.axWindow, windowID: entry.windowID,
              spaceID: entry.spaceID, workspace: entry.aerospaceWorkspace)
    }

    // Single focus path for every real-window row: unhide the app, then
    // jump to the window's non-visible Space when the provider resolved one
    // (making the window key on arrival), switch its hidden AeroSpace
    // workspace when it carries one, else focus directly. Reaching a window
    // in another Space needs a real Space transition - activation alone
    // never performs one. Falls back to a direct focus when navigation is
    // refused or the AeroSpace client died since the snapshot (the window
    // is real either way, and AeroSpace follows externally focused windows
    // when it comes back).
    private func focus(app: NSRunningApplication, element: AXUIElement?, windowID: Int?,
                       spaceID: UInt64?, workspace: String? = nil) {
        // A newer activation supersedes any Space navigation still in
        // flight, including a chain two-hop's pending workspace leg.
        navigator.cancel()
        chain.cancelPending()
        activationGeneration += 1
        lastCommit = (app, Date())
        // Record at commit intent, not on arrival focus: didActivate
        // propagates ~0.1-1s after a switch, but a quick tap lets the user
        // reopen the switcher within ~200ms and that snapshot must already
        // rank this window first. The storm snapshot must also beat the
        // activation's focus-event burst.
        recency.expectActivation(of: app)
        if let windowID {
            recency.noteFocus(windowID: windowID, source: "commit")
        }
        if app.isHidden {
            app.unhide()
        }
        // A window in a hidden AeroSpace workspace sits on THIS native
        // Space, parked off-screen; one AeroSpace command switches the
        // workspace and focuses it.
        if let workspace, let windowID, aerospace.isActive {
            Log.write("focus: aerospace wid=\(windowID) workspace=\(workspace)")
            let generation = activationGeneration
            aerospace.focusWindow(windowID) { [weak self] ok in
                guard let self, !ok, self.activationGeneration == generation else { return }
                self.focusWindow(app: app, element: element, windowID: windowID)
            }
            return
        }
        // A deterministic AltTab-style focus (setFront+click, macOS performs
        // the transition) does NOT work on macOS 26: the app becomes active
        // but the display never leaves the current Space (verified live
        // against a fullscreen target). Reaching a window in another Space
        // needs the real swipe transition below.
        if let spaceID, let windowID,
           navigator.begin(to: spaceID, onArrival: { [weak self] in
               self?.focusWindow(app: app, element: element, windowID: windowID)
           }) {
            Log.write("navigate: pid=\(app.processIdentifier) space=\(spaceID)")
            return
        }
        if spaceID != nil {
            Log.write("otherSpace navigation unavailable for pid=\(app.processIdentifier); focusing directly")
        }
        focusWindow(app: app, element: element, windowID: windowID)
    }

    private func focusWindow(app: NSRunningApplication, element: AXUIElement?, windowID: Int?) {
        if let element, AX.bool(element, kAXMinimizedAttribute) == true {
            AX.setBool(element, kAXMinimizedAttribute, false)
        }
        if let windowID {
            Spaces.makeKey(pid: app.processIdentifier, windowID: windowID)
            if let element {
                AX.raise(element)
            }
        } else if let element {
            AX.raise(element)
            app.activate(options: [.activateIgnoringOtherApps])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
