import AppKit

// State machine for a switcher session: the switcher binding (Cmd+Tab by
// default) starts an app session, the cycle binding (Cmd+`) a window
// session for the frontmost app. While the binding's modifiers are held,
// its key advances (Shift reverses), Esc cancels, and releasing a
// modifier commits the current selection. Bindings come from the cached
// shortcut store and are read per event, so a rebind applies immediately.
final class SwitcherController {
    private let tap = EventTap()
    private let mru: MRUTracker
    private let recency: WindowFocusTracker
    private let aerospace: AeroSpaceClient
    private let panel = SwitcherPanel()
    private let navigator: SpaceNavigator
    private let swipes = DockSwipeRecognizer()
    private lazy var chain = ChainNavigator(navigator: navigator, aerospace: aerospace, recency: recency)

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
    // The newest generation that has applied (committed, or presented as
    // the live session). The windows-snapshot retry can finish AFTER a
    // newer generation committed; its parked pending commit is stale by
    // then and replaying it would yank focus off the user's latest choice
    // (#21). Chained quick taps still replay in order: each pending
    // commit's generation exceeds everything applied before it.
    private var appliedGeneration = 0
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

    // Fired when the key tap dies (e.g. Accessibility revoked at runtime);
    // the owner polls for the grant and calls start() to rebuild.
    var onTapInvalidated: (() -> Void)?

    private let escapeKey: Int64 = 53
    private let upArrowKey: Int64 = 126
    private let downArrowKey: Int64 = 125
    private let jKey: Int64 = 38
    private let kKey: Int64 = 40
    private let qKey: Int64 = 12
    private let wKey: Int64 = 13
    private let commaKey: Int64 = 43

    init(mru: MRUTracker, recency: WindowFocusTracker, aerospace: AeroSpaceClient, events: WindowServerEvents) {
        self.mru = mru
        self.recency = recency
        self.aerospace = aerospace
        self.navigator = SpaceNavigator(events: events, recency: recency)
        tap.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        tap.onFlagsChanged = { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // The toggle is read per event so flipping it in Settings applies
        // immediately; when off, real swipes pass through to the Dock and
        // native behavior is back without a restart.
        tap.onGesture = { [weak self] event in
            guard Settings.trackpadSwipe else { return false }
            return self?.swipes.handle(event) ?? false
        }
        swipes.onSwipe = { [weak self] left in
            // Space navigation, handled off the tap callback so nothing can
            // stall event delivery (same as Ctrl+Arrows).
            DispatchQueue.main.async {
                let detail = self?.chain.navigate(left: left)
                // The arrow is the navigation direction, matching the
                // Ctrl+Arrow flashes, not the finger direction.
                DemoHUD.shared.flash("Swipe \(left ? "←" : "→")", detail: detail)
            }
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

        // A recording in Settings gets the raw press; consuming it keeps
        // half-typed combos from leaking to the focused app.
        if ShortcutRecorder.shared.isRecording {
            return ShortcutRecorder.shared.consume(keyCode: keyCode, flags: flags)
        }

        let outcome = processKeyDown(keyCode: keyCode, flags: flags)
        // Every consumed press is a trigger the demo HUD can announce;
        // the AppKit work is deferred off the tap callback.
        if outcome == .consumed, Settings.demoHud {
            let display = Shortcut(keyCode: keyCode, modifiers: Shortcut.normalized(flags)).display
            DispatchQueue.main.async { DemoHUD.shared.flash(display) }
        }
        return outcome != .passed
    }

    // Whether a press was consumed, and who tells the demo HUD: consumed
    // presses flash generically from handleKeyDown, except chain
    // navigation, which flashes from the navigate path - the transition
    // it announces is only known there.
    private enum KeyDownOutcome { case passed, consumed, consumedAnnounced }

    private func processKeyDown(keyCode: Int64, flags: CGEventFlags) -> KeyDownOutcome {
        let backward = flags.contains(.maskShift)

        let shortcuts = ShortcutSettings.shared
        // Disabled bindings pass through, so the native behavior is back
        // the moment the toggle flips - same per-matched-press defaults
        // read as the Space bindings below.
        if shortcuts.switcher.matches(keyCode: keyCode, flags: flags) {
            guard Settings.appSwitcher else { return .passed }
            advanceApps(backward: backward)
            return .consumed
        }
        if shortcuts.cycleWindows.matches(keyCode: keyCode, flags: flags) {
            guard Settings.windowCycler else { return .passed }
            advanceWindows(backward: backward)
            return .consumed
        }
        // Space navigation never applies inside an open session - the
        // session keys below must win there even when a Space binding
        // shares a combo with one of them (e.g. cmd+j). Match before
        // consulting the toggle: this branch runs for every keystroke
        // system-wide, and the UserDefaults read belongs on the rare
        // matched path, not the reject path.
        if session == nil {
            let previousSpace = shortcuts.previousSpace.matches(keyCode: keyCode, flags: flags)
            if previousSpace || shortcuts.nextSpace.matches(keyCode: keyCode, flags: flags),
               Settings.keyboardSpaceNav {
                let trigger = (previousSpace ? shortcuts.previousSpace : shortcuts.nextSpace).display
                // Space navigation, handled off the tap callback so nothing
                // can stall event delivery.
                DispatchQueue.main.async { [weak self] in
                    let detail = self?.chain.navigate(left: previousSpace)
                    DemoHUD.shared.flash(trigger, detail: detail)
                }
                return .consumedAnnounced
            }
        }

        switch keyCode {
        case escapeKey where session != nil:
            cancel()
            return .consumed
        // List keys live only inside a session (the binding's modifiers
        // held): outside one, arrows, j/k, q, and w pass through untouched.
        case downArrowKey where session != nil, jKey where session != nil:
            advanceCurrent(backward: false)
            return .consumed
        case upArrowKey where session != nil, kKey where session != nil:
            advanceCurrent(backward: true)
            return .consumed
        case qKey where session != nil:
            quitSelected()
            return .consumed
        case wKey where session != nil:
            closeSelectedWindow()
            return .consumed
        // The binding's modifiers are already down in a session, so with
        // the default binding this is Cmd+, - the platform's settings
        // shortcut.
        case commaKey where session != nil:
            cancel()
            DispatchQueue.main.async { SettingsView.showWindow() }
            return .consumed
        default:
            return .passed
        }
    }

    private func advanceCurrent(backward: Bool) {
        switch session {
        case .apps, .pendingApps:
            advanceApps(backward: backward)
        case .windows, .pendingWindows:
            advanceWindows(backward: backward)
        case nil:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        guard let session else { return }
        // The session lives while every modifier of its binding stays
        // down; the first one released commits.
        let binding: Shortcut
        switch session {
        case .apps, .pendingApps: binding = ShortcutSettings.shared.switcher
        case .windows, .pendingWindows: binding = ShortcutSettings.shared.cycleWindows
        }
        let required = binding.modifiers.subtracting(.shift)
        guard !Shortcut.normalized(event.flags).isSuperset(of: required) else { return }
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
            // The AX sweep runs on the snapshot queue, so the main run
            // loop - which services the event taps - never blocks on an
            // unresponsive app; presses and the Cmd release accumulate on
            // the pending session meanwhile. The queue is serial, so
            // snapshots complete in session order and a fresh session
            // started right after a quick tap resolves after the tap's
            // commit. The sweep captures its inputs on main at its start
            // (see SnapshotInputs), behind any prior snapshot's commit.
            session = .pendingApps(presses: [backward])
            snapshotGeneration += 1
            let generation = snapshotGeneration
            // Freshen the workspace cache for commit time and the next
            // session; the sweep reads whatever is captured at its start.
            aerospace.refresh()
            aerospace.kick()
            runSweep(includeApps: true) { inputs in
                let entries = AppListProvider.snapshot(inputs: inputs)
                return { [weak self] in self?.finishAppsSnapshot(entries, generation: generation) }
            }
        }
    }

    // The capture-sweep-finish spine both snapshot kinds share: inputs are
    // captured on main at sweep start (see SnapshotInputs), the sweep runs
    // on the serial snapshot queue, and the continuation it returns lands
    // back on main.
    private func runSweep(includeApps: Bool,
                          sweep: @escaping (SnapshotInputs) -> () -> Void) {
        SnapshotQueue.shared.async { [weak self] in
            guard let self else { return }
            let inputs = DispatchQueue.main.sync {
                SnapshotInputs.capture(mru: self.mru, recency: self.recency,
                                       aerospace: self.aerospace, includeApps: includeApps)
            }
            DispatchQueue.main.async(execute: sweep(inputs))
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
            buildWindowsSnapshot(for: app, appName: app.localizedName ?? "Untitled",
                                 generation: generation, attempt: 0)
        }
    }

    // Shared spine of both snapshot finishes: remember the sweep's
    // elements, replay a parked quick-tap commit unless a newer
    // generation already applied, or resolve the live pending session.
    // `pendingSession` extracts the matching pending case's presses and
    // context (the windows session's target app); mismatched cases fall
    // through the generation guards untouched.
    private func finishSnapshot<Item, Context>(
        _ items: [Item], generation: Int,
        cacheElement: (Item) -> (windowID: Int?, element: AXUIElement?),
        pendingSession: (Session) -> (presses: [Bool], context: Context)?,
        emptyLog: String,
        initialIndex: ([Item], _ backward: Bool) -> Int,
        commit: ([Item], Int, Context) -> Void,
        present: ([Item], Int, Context) -> Void
    ) {
        // Remember every element the sweep saw - even from a stale
        // generation, the elements are real. Cross-Space rows carry none;
        // the repaint nudge resolves theirs from this cache.
        for item in items {
            let handle = cacheElement(item)
            if let windowID = handle.windowID, let element = handle.element {
                WindowElements.note(element, for: windowID)
            }
        }
        // The binding already released: a quick tap commits straight from
        // here, never showing the panel.
        if let pendingIndex = pendingCommits.firstIndex(where: { $0.generation == generation }) {
            let pendingEntry = pendingCommits.remove(at: pendingIndex)
            guard generation > appliedGeneration else {
                Log.write("stale pending commit dropped: generation \(generation) superseded")
                return
            }
            guard let (presses, context) = pendingSession(pendingEntry.session) else { return }
            guard !items.isEmpty else {
                Log.write(emptyLog)
                return
            }
            appliedGeneration = generation
            commit(items, replay(presses, count: items.count,
                                 initial: initialIndex(items, presses[0])), context)
            return
        }
        guard generation == snapshotGeneration,
              let (presses, context) = session.flatMap(pendingSession) else { return }
        guard !items.isEmpty else {
            Log.write(emptyLog)
            session = nil
            return
        }
        appliedGeneration = generation
        present(items, replay(presses, count: items.count,
                              initial: initialIndex(items, presses[0])), context)
    }

    private func finishAppsSnapshot(_ items: [ListEntry], generation: Int) {
        finishSnapshot(
            items, generation: generation,
            cacheElement: { ($0.windowID, $0.axWindow) },
            pendingSession: {
                if case .pendingApps(let presses) = $0 { return (presses, ()) }
                return nil
            },
            emptyLog: "apps snapshot empty; consumed switcher tap dropped",
            initialIndex: { self.initialAppsIndex(items: $0, backward: $1) },
            commit: { items, index, _ in self.activate(items[index]) },
            present: { items, index, _ in
                self.session = .apps(items, index: index)
                self.presentPanel(rows: self.appRows(items), selected: index)
            }
        )
    }

    // Mid Space-transition an app can blow the 0.05s AX messaging timeout
    // and list no windows at all; a session resolved against such a
    // CG-only list commits an other-Space row and mis-navigates (observed
    // as back-to-back jumps to the same Space when the cycle binding is
    // pressed rapidly across Spaces). An AX-blind sweep - as opposed to
    // one whose rows were merely filtered - retries once shortly; the
    // session stays pending and presses accumulate.
    private func buildWindowsSnapshot(for app: NSRunningApplication, appName: String,
                                      generation: Int, attempt: Int) {
        runSweep(includeApps: false) { inputs in
            let snapshot = WindowListProvider.snapshot(for: app, appName: appName, inputs: inputs)
            return { [weak self] in
                guard let self else { return }
                if attempt == 0, !snapshot.sawAXWindows {
                    // Only retry while someone still wants this generation:
                    // the live session, or a parked commit not yet
                    // superseded - a superseded retry would sweep for a
                    // result the finish discards anyway. The retry waits on
                    // MAIN and re-dispatches: a delayed block on the serial
                    // queue would lose its FIFO slot, and sleeping on the
                    // queue would block newer work.
                    let wanted = generation == self.snapshotGeneration
                        || (generation > self.appliedGeneration
                            && self.pendingCommits.contains { $0.generation == generation })
                    if wanted {
                        Log.write("windows snapshot: no AX rows for pid=\(app.processIdentifier); retrying")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                            self?.buildWindowsSnapshot(for: app, appName: appName,
                                                       generation: generation, attempt: 1)
                        }
                        return
                    }
                }
                self.finishWindowsSnapshot(snapshot.items, generation: generation)
            }
        }
    }

    private func finishWindowsSnapshot(_ items: [WindowItem], generation: Int) {
        finishSnapshot(
            items, generation: generation,
            cacheElement: { ($0.windowID, $0.element) },
            pendingSession: {
                if case .pendingWindows(let app, let presses) = $0 { return (presses, app) }
                return nil
            },
            emptyLog: "window snapshot empty; consumed cycle tap dropped",
            initialIndex: { items, backward in self.startIndex(count: items.count, backward: backward) },
            commit: { items, index, app in
                let item = items[index]
                self.focus(app: app, element: item.element, windowID: item.windowID,
                           spaceID: item.spaceID, workspace: item.aerospaceWorkspace)
            },
            present: { items, index, app in
                self.session = .windows(app, items, index: index)
                self.presentPanel(rows: self.windowRows(app, items), selected: index)
            }
        )
    }

    private func appRows(_ items: [ListEntry]) -> [SwitcherRow] {
        items.map {
            SwitcherRow(icon: $0.app.icon, title: $0.appName, subtitle: $0.windowTitle,
                        annotation: annotation(for: $0))
        }
    }

    private func windowRows(_ app: NSRunningApplication, _ items: [WindowItem]) -> [SwitcherRow] {
        items.map {
            SwitcherRow(icon: app.icon, title: $0.title, subtitle: nil,
                        annotation: annotation(for: $0))
        }
    }

    // The first press picked the start index; each further press steps.
    private func replay(_ presses: [Bool], count: Int, initial: Int) -> Int {
        presses.dropFirst().reduce(initial) { index, backward in
            step(index, count: count, backward: backward)
        }
    }

    // The current-window authority answers this in single-digit ms for
    // every switch Cyclist makes; NSWorkspace (which lags those switches
    // by ~0.1-1s) remains only as the cold-start fallback.
    private func frontmostForSessions() -> NSRunningApplication? {
        if let pid = recency.currentWindow?.pid,
           let app = NSRunningApplication(processIdentifier: pid) {
            return app
        }
        return NSWorkspace.shared.frontmostApplication
    }

    // A quick tap goes to the previously used WINDOW, wherever it lives:
    // after deliberately visiting two windows of one app, the sibling
    // window is the suggestion, not another app - and after coming from
    // another app, that app's window outranks the stale sibling. One rule
    // covers both: the best-ranked window that is not the one holding
    // focus. The held window is the current-window authority - fed by our
    // own commits at intent time (so it is never stale mid-transition,
    // where the WindowServer z-order lies) and by accepted focus events
    // for switches made outside Cyclist. Rows without ranks fall back to
    // the previous-app heuristic.
    private func initialAppsIndex(items: [ListEntry], backward: Bool) -> Int {
        if backward { return items.count - 1 }
        let current = recency.currentWindow?.windowID
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

    // Finder ignores a normal quit and relaunches itself, so quitting it
    // would silently drop the row without terminating anything. Gate it on
    // the same opt-in the Dock and AltTab honor:
    //   defaults write com.apple.finder QuitMenuItem -bool true
    private func canQuit(_ app: NSRunningApplication) -> Bool {
        guard app.bundleIdentifier == "com.apple.finder" else { return true }
        return UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "QuitMenuItem") ?? false
    }

    // Quit the selected row's app, like native Cmd+Tab's Q: its rows leave
    // the list and the session continues on whatever remains.
    private func quitSelected() {
        switch session {
        case .apps(let items, let index):
            let app = items[index].app
            guard canQuit(app) else {
                Log.write("quit: \(items[index].appName) is not quittable")
                NSSound.beep()
                return
            }
            Log.write("quit: app=\(items[index].appName) pid=\(app.processIdentifier)")
            app.terminate()
            let survivors = items.enumerated().filter {
                $0.element.app.processIdentifier != app.processIdentifier
            }
            applyAppsSession(survivors.map(\.element),
                             selectedNear: survivors.filter { $0.offset < index }.count)
        case .windows(let app, _, _):
            guard canQuit(app) else {
                Log.write("quit: \(app.localizedName ?? "?") is not quittable")
                NSSound.beep()
                return
            }
            // Every row belongs to the quit app; nothing left to browse.
            Log.write("quit: app=\(app.localizedName ?? "?") pid=\(app.processIdentifier)")
            app.terminate()
            cancel()
        case .pendingApps, .pendingWindows, nil:
            break
        }
    }

    // Close just the selected window. Only rows with an AX element can
    // close - other-Space rows carry no handle to press.
    private func closeSelectedWindow() {
        switch session {
        case .apps(let items, let index):
            let entry = items[index]
            guard let element = entry.axWindow else {
                Log.write("close: no AX handle for \(entry.appName)")
                return
            }
            Log.write("close: app=\(entry.appName) wid=\(entry.windowID.map(String.init) ?? "-")")
            AX.close(element)
            var remaining = items
            remaining.remove(at: index)
            applyAppsSession(remaining, selectedNear: index)
        case .windows(let app, let items, let index):
            let item = items[index]
            guard let element = item.element else {
                Log.write("close: no AX handle for wid=\(item.windowID.map(String.init) ?? "-")")
                return
            }
            Log.write("close: app=\(app.localizedName ?? "?") wid=\(item.windowID.map(String.init) ?? "-")")
            AX.close(element)
            var remaining = items
            remaining.remove(at: index)
            guard !remaining.isEmpty else {
                cancel()
                return
            }
            let clamped = min(index, remaining.count - 1)
            session = .windows(app, remaining, index: clamped)
            panel.setRows(windowRows(app, remaining), selected: clamped)
        case .pendingApps, .pendingWindows, nil:
            break
        }
    }

    private func applyAppsSession(_ items: [ListEntry], selectedNear index: Int) {
        guard !items.isEmpty else {
            cancel()
            return
        }
        let clamped = min(index, items.count - 1)
        session = .apps(items, index: clamped)
        panel.setRows(appRows(items), selected: clamped)
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
    // previous window without a visual flash.
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
            // Unreachable: the only caller is handleFlagsChanged's
            // .apps/.windows arm. Pending sessions commit from their
            // snapshot completion instead.
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
            recency.noteCommit(app: app, windowID: nil)
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
        // Record at commit intent, not on arrival focus: didActivate
        // propagates ~0.1-1s after a switch, but a quick tap lets the user
        // reopen the switcher within ~200ms and that snapshot must already
        // rank this window first - and the current-window authority must
        // already point here. The storm snapshot must also beat the
        // activation's focus-event burst.
        recency.expectActivation(of: app)
        recency.noteCommit(app: app, windowID: windowID)
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
               // A window reached in another Space can arrive with a purged
               // backing (blank though focused); a geometry nudge repaints it.
               AX.repaintNudge(pid: app.processIdentifier, windowID: windowID, element: element)
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
