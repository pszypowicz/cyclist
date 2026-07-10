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
        let otherModifiers = flags.contains(.maskControl) || flags.contains(.maskAlternate)

        let controlOnly = flags.contains(.maskControl) && !command && !backward
            && !flags.contains(.maskAlternate)

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
            // Workspace/Space chain navigation. Handled off the tap callback
            // so AeroSpace CLI calls cannot stall the tap.
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
            focus(items[index], of: app)
        }
    }

    private func activate(_ entry: ListEntry) {
        let app = entry.app
        // A newer activation supersedes any Space navigation still in flight.
        navigator.cancel()
        Log.write("activate: app=\(entry.appName) state=\(entry.state)"
            + " windowID=\(entry.windowID.map(String.init) ?? "-")"
            + " spaceID=\(entry.spaceID.map(String.init) ?? "-")"
            + " from=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        // Plain activation does nothing visible for an app with no windows.
        // Launching it again is Dock-click semantics: the app gets a reopen
        // event and recreates its window.
        if entry.state == .noWindows, let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        // Reaching a window in another Space needs a real Mission Control
        // transition, which only the Dock can perform: navigate there with
        // the synthesized Ctrl+Arrow shortcut, then make the target window
        // key. A Dock icon press is the fallback (it activates natively but
        // does not enter fullscreen Spaces). The make-key also covers
        // same-Space rows: since macOS 14, NSRunningApplication.activate is
        // an advisory request the system ignores from here, so it cannot
        // move activation (or the menu bar) by itself.
        if entry.state == .otherSpace {
            let pid = app.processIdentifier
            let windowID = entry.windowID
            if let spaceID = entry.spaceID,
               navigator.begin(to: spaceID, onArrival: windowID.map { wid in
                   { Spaces.makeKey(pid: pid, windowID: wid) }
               }) {
                Log.write("navigate: \(entry.appName) space=\(spaceID)")
                return
            }
            if Dock.pressIcon(named: entry.appName) {
                Log.write("dock press: \(entry.appName)")
                return
            }
            Log.write("otherSpace activation fallback for \(entry.appName)")
        }
        if app.isHidden {
            app.unhide()
        }
        if let window = entry.axWindow, AX.bool(window, kAXMinimizedAttribute) == true {
            AX.setBool(window, kAXMinimizedAttribute, false)
        }
        // Rapid switching can leave AX still listing windows of the Space
        // just left, so a "normal" row may actually live in a non-visible
        // Space; focusing it alone would move the menu bar without the
        // Space. Verify real Space membership and reroute.
        if entry.state == .normal, let windowID = entry.windowID {
            for (space, windowIDs) in Spaces.windowsByNonVisibleSpace()
            where windowIDs.contains(windowID) {
                Log.write("activate: window \(windowID) is actually in space \(space), navigating")
                let pid = app.processIdentifier
                _ = navigator.begin(to: space) {
                    Spaces.makeKey(pid: pid, windowID: windowID)
                }
                return
            }
        }
        if let windowID = entry.windowID {
            Spaces.makeKey(pid: app.processIdentifier, windowID: windowID)
            if let window = entry.axWindow {
                AX.raise(window)
            }
        } else if let window = entry.axWindow {
            AX.raise(window)
            app.activate(options: [.activateIgnoringOtherApps])
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func focus(_ item: WindowItem, of app: NSRunningApplication) {
        if item.isMinimized {
            AX.setBool(item.element, kAXMinimizedAttribute, false)
        }
        if let windowID = item.windowID {
            Spaces.makeKey(pid: app.processIdentifier, windowID: windowID)
            AX.raise(item.element)
        } else {
            AX.raise(item.element)
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
