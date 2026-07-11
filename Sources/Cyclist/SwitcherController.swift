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
    private let swipeDetector = SwipeDetector()

    private enum Session {
        case apps([ListEntry], index: Int)
        case windows(NSRunningApplication, [WindowItem], index: Int)
    }
    private var session: Session?
    private var showPanelWork: DispatchWorkItem?

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
        tap.onGesture = { [weak self] event in
            self?.swipeDetector.handle(event)
        }
        // Natural-scroll convention, matching the trackpad: fingers left
        // moves forward through the chain, fingers right moves back.
        swipeDetector.onSwipe = { [weak self] fingersLeft in
            DispatchQueue.main.async { self?.chain.navigate(left: !fingersLeft) }
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
        guard session != nil else { return }
        if !event.flags.contains(.maskCommand) {
            commit()
        }
    }

    private func advanceApps(backward: Bool) {
        switch session {
        case .apps(let items, let index):
            let next = step(index, count: items.count, backward: backward)
            session = .apps(items, index: next)
            panel.select(index: next)
        case .windows:
            break
        case nil:
            let items = AppListProvider.snapshot(mru: mru)
            guard !items.isEmpty else { return }
            // A quick tap should land on the previous app, not on another
            // window of the frontmost app, whose windows head the MRU list.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let firstOtherApp = items.firstIndex { $0.app.processIdentifier != front }
            let forwardStart = firstOtherApp ?? (items.count > 1 ? 1 : 0)
            let start = backward ? items.count - 1 : forwardStart
            session = .apps(items, index: start)
            presentPanel(
                rows: items.map {
                    SwitcherRow(icon: $0.app.icon, title: $0.appName, subtitle: $0.windowTitle,
                                annotation: annotation(for: $0))
                },
                selected: start
            )
        }
    }

    private func advanceWindows(backward: Bool) {
        switch session {
        case .windows(let app, let items, let index):
            let next = step(index, count: items.count, backward: backward)
            session = .windows(app, items, index: next)
            panel.select(index: next)
        case .apps:
            break
        case nil:
            guard let app = NSWorkspace.shared.frontmostApplication else { return }
            let items = WindowListProvider.snapshot(for: app)
            guard !items.isEmpty else { return }
            let start = startIndex(count: items.count, backward: backward)
            session = .windows(app, items, index: start)
            presentPanel(
                rows: items.map {
                    SwitcherRow(icon: app.icon, title: $0.title, subtitle: nil,
                                annotation: $0.isMinimized ? "minimized" : nil)
                },
                selected: start
            )
        }
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
        self.session = nil
        dismissPanel()
        switch session {
        case .apps(let items, let index):
            activate(items[index])
        case .windows(let app, let items, let index):
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
