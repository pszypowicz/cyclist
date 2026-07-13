import AppKit

// State machine for a switcher session: Cmd+Tab starts an app session,
// Cmd+` starts a window session for the frontmost app. While Cmd is held,
// Tab/backtick advance (Shift reverses), Esc cancels, and releasing Cmd
// commits the current selection.
final class SwitcherController {
    private let tap = EventTap()
    private let mru: MRUTracker
    private let panel = SwitcherPanel()
    private let navigator = SpaceNavigator()
    private lazy var chain = ChainNavigator(navigator: navigator)

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

    // Fired when the key tap dies (e.g. Accessibility revoked at runtime);
    // the owner polls for the grant and calls start() to rebuild.
    var onTapInvalidated: (() -> Void)?

    private let tabKey: Int64 = 48
    private let graveKey: Int64 = 50
    private let escapeKey: Int64 = 53
    private let leftArrowKey: Int64 = 123
    private let rightArrowKey: Int64 = 124

    init(mru: MRUTracker) {
        self.mru = mru
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
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.finishAppsSnapshot(AppListProvider.snapshot(mru: self.mru), generation: generation)
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
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            session = .pendingWindows(app, presses: [backward])
            snapshotGeneration += 1
            let generation = snapshotGeneration
            DispatchQueue.main.async { [weak self] in
                self?.finishWindowsSnapshot(WindowListProvider.snapshot(for: app), generation: generation)
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
            focus(app: app, element: item.element, windowID: item.windowID, spaceID: item.spaceID)
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
                            annotation: $0.isMinimized ? "minimized" : nil)
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

    // A quick tap should land on the previous app, not on another window of
    // the frontmost app, whose windows head the MRU list.
    private func initialAppsIndex(items: [ListEntry], backward: Bool) -> Int {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let firstOtherApp = items.firstIndex { $0.app.processIdentifier != front }
        let forwardStart = firstOtherApp ?? (items.count > 1 ? 1 : 0)
        return backward ? items.count - 1 : forwardStart
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
        case .noWindows: return "no windows"
        }
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
            focus(app: app, element: item.element, windowID: item.windowID, spaceID: item.spaceID)
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
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        focus(app: app, element: entry.axWindow, windowID: entry.windowID, spaceID: entry.spaceID)
    }

    // Single focus path for every real-window row: unhide the app, jump to
    // the window's non-visible Space when the provider resolved one (making
    // the window key on arrival), else focus directly. Reaching a window in
    // another Space needs a real Space transition - activation alone never
    // performs one. Falls back to a direct focus when navigation is refused.
    private func focus(app: NSRunningApplication, element: AXUIElement?, windowID: Int?, spaceID: UInt64?) {
        // A newer activation supersedes any Space navigation still in flight.
        navigator.cancel()
        if app.isHidden {
            app.unhide()
        }
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
