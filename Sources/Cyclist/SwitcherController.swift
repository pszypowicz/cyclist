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
    // NSWorkspace's frontmost app lags a makeKey/AeroSpace activation by
    // ~0.1-1s. A press inside that window would classify rows against the
    // app just left: a quick Cmd+Tab re-commits the very window the user
    // is on, and Cmd+` lists the wrong app's windows. Right after our own
    // commit, we are the fresher source of truth.
    private var lastCommit: (app: NSRunningApplication, at: Date)?
    private var activationObserver: NSObjectProtocol?

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
            DispatchQueue.main.async { self?.chain.navigate(left: left) }
        }
        tap.onInvalidated = { [weak self] in
            self?.onTapInvalidated?()
        }
        // A genuine user-driven app switch (mouse, Dock) supersedes the
        // commit bridge: holding lastCommit for its full 1.5s made a quick
        // window-cycle right after such a switch list the COMMITTED app's
        // windows instead of the frontmost one (#22). Cyclist's own
        // activation notifications lag their commit by up to ~1s, so a
        // cross-app arrival right after a rapid double-commit belongs to
        // the superseded commit and must not clear the fresh bridge - the
        // 0.2s grace covers that, at the cost of a user switch inside
        // those 200ms still hitting the stale bridge.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let lastCommit = self.lastCommit,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != lastCommit.app.processIdentifier,
                  Date().timeIntervalSince(lastCommit.at) > 0.2 else { return }
            self.lastCommit = nil
        }
    }

    func start() -> Bool {
        tap.start()
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let backward = flags.contains(.maskShift)

        // A recording in Settings gets the raw press; consuming it keeps
        // half-typed combos from leaking to the focused app.
        if ShortcutRecorder.shared.isRecording {
            return ShortcutRecorder.shared.consume(keyCode: keyCode, flags: flags)
        }

        let shortcuts = ShortcutSettings.shared
        if shortcuts.switcher.matches(keyCode: keyCode, flags: flags) {
            advanceApps(backward: backward)
            return true
        }
        if shortcuts.cycleWindows.matches(keyCode: keyCode, flags: flags) {
            advanceWindows(backward: backward)
            return true
        }
        // Match before consulting the toggle: this branch runs for every
        // keystroke system-wide, and the UserDefaults read belongs on the
        // rare matched path, not the reject path.
        let previousSpace = shortcuts.previousSpace.matches(keyCode: keyCode, flags: flags)
        if previousSpace || shortcuts.nextSpace.matches(keyCode: keyCode, flags: flags),
           Settings.keyboardSpaceNav {
            // Space navigation, handled off the tap callback so nothing can
            // stall event delivery.
            DispatchQueue.main.async { [weak self] in self?.chain.navigate(left: previousSpace) }
            return true
        }

        switch keyCode {
        case escapeKey where session != nil:
            cancel()
            return true
        // List keys live only inside a session (the binding's modifiers
        // held): outside one, arrows, j/k, q, and w pass through untouched.
        case downArrowKey where session != nil, jKey where session != nil:
            advanceCurrent(backward: false)
            return true
        case upArrowKey where session != nil, kKey where session != nil:
            advanceCurrent(backward: true)
            return true
        case qKey where session != nil:
            quitSelected()
            return true
        case wKey where session != nil:
            closeSelectedWindow()
            return true
        // The binding's modifiers are already down in a session, so with
        // the default binding this is Cmd+, - the platform's settings
        // shortcut.
        case commaKey where session != nil:
            cancel()
            DispatchQueue.main.async { SettingsView.showWindow() }
            return true
        default:
            return false
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
            SnapshotQueue.shared.async { [weak self] in
                guard let self else { return }
                let inputs = DispatchQueue.main.sync {
                    SnapshotInputs.capture(mru: self.mru, recency: self.recency, aerospace: self.aerospace)
                }
                let entries = AppListProvider.snapshot(inputs: inputs)
                DispatchQueue.main.async {
                    self.finishAppsSnapshot(entries, generation: generation)
                }
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
            buildWindowsSnapshot(for: app, appName: app.localizedName ?? "Untitled",
                                 generation: generation, attempt: 0)
        }
    }

    private func finishAppsSnapshot(_ items: [ListEntry], generation: Int) {
        // Remember every element the sweep saw - even from a stale
        // generation, the elements are real. Cross-Space rows carry none;
        // the repaint nudge resolves theirs from this cache.
        for item in items {
            if let windowID = item.windowID, let element = item.axWindow {
                WindowElements.note(element, for: windowID)
            }
        }
        // Cmd already released: a quick tap commits straight from here,
        // never showing the panel.
        if let pendingIndex = pendingCommits.firstIndex(where: { $0.generation == generation }) {
            let pending = pendingCommits.remove(at: pendingIndex)
            guard generation > appliedGeneration else {
                Log.write("stale pending commit dropped: generation \(generation) superseded")
                return
            }
            guard case .pendingApps(let presses) = pending.session else { return }
            guard !items.isEmpty else {
                Log.write("apps snapshot empty; consumed Cmd+Tab dropped")
                return
            }
            appliedGeneration = generation
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
        appliedGeneration = generation
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
    private func buildWindowsSnapshot(for app: NSRunningApplication, appName: String,
                                      generation: Int, attempt: Int) {
        SnapshotQueue.shared.async { [weak self] in
            guard let self else { return }
            let inputs = DispatchQueue.main.sync {
                SnapshotInputs.capture(mru: self.mru, recency: self.recency, aerospace: self.aerospace)
            }
            let items = WindowListProvider.snapshot(for: app, appName: appName, inputs: inputs)
            DispatchQueue.main.async {
                if attempt == 0, !items.contains(where: { $0.element != nil }) {
                    Log.write("windows snapshot: no AX rows for pid=\(app.processIdentifier); retrying")
                    // The retry waits on MAIN and re-dispatches: a delayed
                    // block on the serial queue would lose its FIFO slot,
                    // and sleeping on the queue would block newer work.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        self?.buildWindowsSnapshot(for: app, appName: appName,
                                                   generation: generation, attempt: 1)
                    }
                    return
                }
                self.finishWindowsSnapshot(items, generation: generation)
            }
        }
    }

    private func finishWindowsSnapshot(_ items: [WindowItem], generation: Int) {
        for item in items {
            if let windowID = item.windowID, let element = item.element {
                WindowElements.note(element, for: windowID)
            }
        }
        if let pendingIndex = pendingCommits.firstIndex(where: { $0.generation == generation }) {
            let pending = pendingCommits.remove(at: pendingIndex)
            guard generation > appliedGeneration else {
                Log.write("stale pending commit dropped: generation \(generation) superseded")
                return
            }
            guard case .pendingWindows(let app, let presses) = pending.session else { return }
            guard !items.isEmpty else {
                Log.write("window snapshot empty; consumed Cmd+` dropped")
                return
            }
            appliedGeneration = generation
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
        appliedGeneration = generation
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
    // focus. The held window comes from the WindowServer's z-order (the
    // topmost on-screen real window), not from the focus-event stream:
    // event-derived "current" goes stale in the gap between a focus
    // change and its notifications, and a stale exclusion makes the tap
    // re-commit the very window the user is on. The realness filter matters
    // on a fullscreen Space: its slide-down toolbar is a layer-0 ~88pt
    // window that tops the plain CGWindowList, so without the filter the
    // strip - not the content window - reads as current, the content window
    // is never excluded, and a quick tap re-commits the fullscreen app to
    // itself instead of the previous window. Rows without ranks fall back to
    // the previous-app heuristic.
    private func initialAppsIndex(items: [ListEntry], backward: Bool) -> Int {
        if backward { return items.count - 1 }
        // While our own Space navigation settles, the z-order lags
        // compositing: the window just left can still read as top-on-screen,
        // which excludes the true bounce target (the tap veers to a third
        // window and drops the fullscreen partner from the rotation) or
        // fails to exclude the true current one (the tap re-commits it).
        // The ranks have neither problem there - commits record their
        // target at intent time and transition raise noise is suppressed -
        // so the top rank IS the current window. Outside a settle window
        // the z-order stays authoritative: a mouse-clicked focus is current
        // in the z-order immediately but unranked until its event arrives.
        let current = recency.navigationSettling
            ? recency.topRankedWindowID()
            : Spaces.topOnScreenRealWindow()
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
            panel.setRows(remaining.map {
                SwitcherRow(icon: app.icon, title: $0.title, subtitle: nil,
                            annotation: annotation(for: $0))
            }, selected: clamped)
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
        panel.setRows(items.map {
            SwitcherRow(icon: $0.app.icon, title: $0.appName, subtitle: $0.windowTitle,
                        annotation: annotation(for: $0))
        }, selected: clamped)
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
