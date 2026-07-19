import AppKit

// Ctrl+Left/Right walks the native Spaces of the active display in
// Mission Control order - user desktops and fullscreen
// Spaces alike - with instant, animation-free jumps. Arriving on a user
// Space focuses its top window, so stepping out of a fullscreen app always
// lands on something concrete instead of leaving the fullscreen app's menu
// bar behind.
//
// With AeroSpace active, its workspaces splice into the ring in place of
// the desktop Space hosting them (AeroSpace emulates workspaces inside one
// native Space, invisible to Space bookkeeping): the ring becomes
// [ws 1 ... ws N, fullscreen Spaces...], so entering the desktop from a
// fullscreen Space on its right lands on the last workspace and from the
// left on the first - spatially consistent in both directions. Workspace
// steps are a socket command instead of a swipe; crossing from a
// fullscreen Space to a workspace is a native hop to the host desktop
// with the workspace switch chained onto the verified arrival. Workspaces
// whose windows all went native-fullscreen are hollow (visiting one shows
// a bare desktop) and lose their ring stop unless a setting keeps them.
// When the client is inactive the ring, base, and arrival behavior are
// exactly the native code path.
final class ChainNavigator {
    private let navigator: SpaceNavigator
    private let aerospace: AeroSpaceClient
    private let recency: WindowFocusTracker

    private enum RingElement: Equatable {
        case native(UInt64)
        case workspace(String, host: UInt64)
    }

    // A direct workspace switch answers in ~10-30ms; past that the press
    // was lost and the next one should re-read reality. The two-hop grace
    // covers the paced native leg before the switch can even be issued:
    // each hop is event-gated on the previous transition landing plus the
    // settle gap, so a dropped swipe's verified arrival can land seconds
    // later.
    private let directSwitchGrace: TimeInterval = 0.3
    private let hopSwitchGrace: TimeInterval = 5.0

    // The in-flight workspace destination. AeroSpace steps never go
    // through SpaceNavigator, so the chain keeps its own pending notion
    // for the same reason SpaceNavigator has pendingTarget: rapid presses
    // must chain from where navigation is already headed, not from the
    // (stale) focused workspace.
    private var pendingWorkspace: (name: String, host: UInt64, expires: Date)?

    init(navigator: SpaceNavigator, aerospace: AeroSpaceClient, recency: WindowFocusTracker) {
        self.navigator = navigator
        self.aerospace = aerospace
        self.recency = recency
    }

    // Callers that cancel the underlying SpaceNavigator (a switcher
    // activation superseding an in-flight two-hop) must drop the pending
    // workspace with it, or the next press would step relative to a
    // destination that was never reached.
    func cancelPending() {
        pendingWorkspace = nil
    }

    // Returns the demo HUD's line for the step it initiated ("workspace 2
    // → Safari (fullscreen)"), nil when nothing was (HUD off, edge of the
    // ring, no ring position).
    @discardableResult
    func navigate(left: Bool) -> String? {
        guard let display = Spaces.activeDisplayInfo() else {
            Log.write("chain: no display info")
            return nil
        }
        // Self-heal a stranded client (missed enable event, exhausted
        // reconnect); async and debounced, never affects this press.
        aerospace.kick()
        guard let (ring, baseIndex) = resolveRing(display) else {
            Log.write("chain: position not in ring; current \(display.current)"
                + " pending \(navigator.pendingTarget.map(String.init) ?? "-")"
                + " order \(display.order)")
            return nil
        }
        let base = ring[baseIndex]
        let targetIndex = baseIndex + (left ? -1 : 1)
        guard ring.indices.contains(targetIndex) else {
            Log.write("chain: at \(left ? "left" : "right") edge of \(ring.map(describe))")
            return nil
        }
        let direction = left ? "left" : "right"
        // Resolved before the step so the labels read the pre-transition
        // state; the SLS lookups behind the fullscreen label only run
        // while the HUD wants them.
        let hudDetail = Settings.demoHud
            ? "\(hudLabel(base, display)) → \(hudLabel(ring[targetIndex], display))" : nil

        switch ring[targetIndex] {
        case .native(let id):
            pendingWorkspace = nil
            Log.write("chain: \(direction) \(describe(base)) -> space \(id)")
            let arrival: (() -> Void)? = display.types[id] == 0
                ? { [weak self] in self?.focusTopUserWindow() }
                : nil
            _ = navigator.begin(to: id, onArrival: arrival)

        case .workspace(let name, let host) where display.current == host && navigator.pendingTarget == nil:
            // Already on the host desktop: a plain workspace switch.
            // AeroSpace transfers focus itself, so no arrival focus here.
            pendingWorkspace = (name, host, Date().addingTimeInterval(directSwitchGrace))
            Log.write("chain: \(direction) \(describe(base)) -> workspace \(name)")
            aerospace.switchToWorkspace(name) { [weak self] ok in
                guard let self, self.pendingWorkspace?.name == name else { return }
                self.pendingWorkspace = nil
                if !ok {
                    Log.write("chain: workspace switch to \(name) failed")
                }
            }

        case .workspace(let name, let host):
            // On a fullscreen Space (or mid-hop): native jump to the host
            // desktop first, workspace switch after verified arrival.
            // Rapid presses retarget pendingWorkspace while the hop is in
            // flight; the arrival closure reads the latest, and a repeated
            // begin() to the same host just replaces the arrival handler.
            pendingWorkspace = (name, host, Date().addingTimeInterval(hopSwitchGrace))
            Log.write("chain: \(direction) \(describe(base)) -> space \(host) + workspace \(name)")
            let started = navigator.begin(to: host, onArrival: { [weak self] in
                guard let self else { return }
                let target = self.pendingWorkspace?.host == host
                    ? (self.pendingWorkspace?.name ?? name) : name
                // failIfNoop: when the target is already AeroSpace's focused
                // workspace the switch would succeed without focusing
                // anything, leaving key focus behind on the fullscreen app.
                // The noop then lands in the failure branch, whose fallback
                // is exactly the native arrival focus.
                self.aerospace.switchToWorkspace(target, failIfNoop: true) { [weak self] ok in
                    guard let self, self.pendingWorkspace?.name == target else { return }
                    self.pendingWorkspace = nil
                    if !ok {
                        // Keep the fullscreen-exit guarantee of landing on
                        // something concrete even if the client just died.
                        self.focusTopUserWindow()
                    }
                }
            })
            if !started {
                pendingWorkspace = nil
            }
        }
        return hudDetail
    }

    // Demo-HUD label for a ring stop, in Mission Control's nomenclature:
    // AeroSpace workspaces by name, user desktops as "desktop", and a
    // fullscreen Space by the app it shows (any real window's owner - a
    // split-view Space names just one of its apps).
    private func hudLabel(_ element: RingElement, _ display: DisplayInfo) -> String {
        switch element {
        case .workspace(let name, _):
            return "workspace \(name)"
        case .native(let id):
            guard display.types[id] != 0 else { return "desktop" }
            if let windowID = Spaces.realWindows(among: Spaces.windowIDs(inSpace: id)).first,
               let pid = CGWindows.realOwner(of: windowID)?.pid,
               let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
                return "\(name) (fullscreen)"
            }
            return "fullscreen"
        }
    }

    // MARK: - ring construction

    private typealias DisplayInfo = Spaces.DisplayInfo

    private func resolveRing(_ display: DisplayInfo) -> ([RingElement], Int)? {
        // A mid-refresh cache (focused workspace not in the list yet)
        // degrades this press to a pure native step rather than guessing.
        if let host = chooseHost(display), let resolved = ringAndBase(display, host: host) {
            return resolved
        }
        return ringAndBase(display, host: nil)
    }

    private func ringAndBase(_ display: DisplayInfo, host: UInt64?) -> ([RingElement], Int)? {
        let ring = buildRing(display, host: host)
        guard let index = baseIndex(in: ring, display: display, host: host) else { return nil }
        return (ring, index)
    }

    // The desktop Space whose place in the ring the workspaces take. With
    // one user desktop (the recommended AeroSpace setup) it is that one;
    // with several, only the current desktop is safe to expand - from a
    // fullscreen Space there is no telling which desktop AeroSpace would
    // show on, so the ring stays native rather than guessing.
    private func chooseHost(_ display: DisplayInfo) -> UInt64? {
        guard aerospace.isActive, !aerospace.workspaces.isEmpty else { return nil }
        let desktops = display.order.filter { display.types[$0] == 0 }
        if desktops.count == 1 { return desktops[0] }
        if display.types[display.current] == 0 { return display.current }
        return nil
    }

    private func buildRing(_ display: DisplayInfo, host: UInt64?) -> [RingElement] {
        guard let host else { return display.order.map { .native($0) } }
        let names = ringWorkspaces(display, host: host)
        return display.order.flatMap { id -> [RingElement] in
            guard id == host else { return [.native(id)] }
            return names.map { .workspace($0, host: host) }
        }
    }

    // The workspaces that earn a ring stop. A workspace is hollow when
    // every window AeroSpace assigns it resides on a fullscreen Space:
    // visiting one shows a bare desktop - the windows display elsewhere,
    // and AeroSpace keeps them assigned only so they return on fullscreen
    // exit - so the chain skips it and the fullscreen Space itself is the
    // stop that shows something. The focused workspace keeps its stop only
    // while the desktop is (or is about to be) the position a press steps
    // from - there it is the base and dropping it would break base
    // resolution. Standing on a fullscreen Space, AeroSpace attributes
    // focus to the workspace of the fullscreen window itself, and keeping
    // that stop would resurrect exactly the hollow stop being skipped.
    // When filtering would drop every workspace, all stay - the desktop
    // must remain reachable from a fullscreen Space.
    private func ringWorkspaces(_ display: DisplayInfo, host: UInt64) -> [String] {
        let all = aerospace.workspaces
        if Settings.showHollowWorkspaces { return all }
        var fullscreenResidents: Set<Int> = []
        for id in display.order where display.types[id] != 0 {
            fullscreenResidents.formUnion(Spaces.windowIDs(inSpace: id))
        }
        let baseWorkspace = display.current == host || navigator.pendingTarget == host
            ? aerospace.focusedWorkspace : nil
        let kept = all.filter { name in
            name == baseWorkspace || !isHollow(name, fullscreenResidents: fullscreenResidents)
        }
        if kept.count != all.count {
            Log.debug("chain: hollow workspaces skipped: \(all.filter { !kept.contains($0) })")
        }
        return kept.isEmpty ? all : kept
    }

    // The client's workspace list is filtered to occupied-or-focused, so a
    // windowless workspace only shows up here in a refresh race; treating
    // it as hollow errs toward the fresher truth. The failure bias runs the
    // other way for residents: an SLS hiccup that returns no fullscreen
    // windows keeps every workspace visible rather than dropping stops.
    private func isHollow(_ name: String, fullscreenResidents: Set<Int>) -> Bool {
        let windows = aerospace.windowIDs(inWorkspace: name)
        guard !windows.isEmpty else { return true }
        return windows.allSatisfy(fullscreenResidents.contains)
    }

    // Where this press steps from: the in-flight workspace switch, then
    // the in-flight native hop, then the real current position. Returning
    // the ring index directly keeps membership and position one lookup.
    private func baseIndex(in ring: [RingElement], display: DisplayInfo, host: UInt64?) -> Int? {
        if let pending = pendingWorkspace, pending.expires > Date(),
           let index = ring.firstIndex(of: .workspace(pending.name, host: pending.host)) {
            return index
        }
        if let inFlight = navigator.pendingTarget {
            if inFlight == host {
                // The hop lands on the host desktop, which shows its
                // focused workspace.
                guard let focused = aerospace.focusedWorkspace else { return nil }
                return ring.firstIndex(of: .workspace(focused, host: inFlight))
            }
            // An in-flight target missing from the order means the display
            // configuration moved under the navigation; stop rather than
            // base on stale state and hijack another display's Spaces.
            return ring.firstIndex(of: .native(inFlight))
        }
        if display.current == host {
            guard let focused = aerospace.focusedWorkspace else { return nil }
            return ring.firstIndex(of: .workspace(focused, host: display.current))
        }
        return ring.firstIndex(of: .native(display.current))
    }

    private func describe(_ element: RingElement) -> String {
        switch element {
        case .native(let id): return "space \(id)"
        case .workspace(let name, _): return "workspace \(name)"
        }
    }

    // Front-to-back on-screen window list; the first regular-app window on
    // the active display is what the user sees on top of the Space just
    // arrived at. The center-point test keeps windows overhanging from a
    // neighboring display out (CGWindowList bounds and CGDisplayBounds share
    // the same global top-left-origin coordinates); it also excludes
    // AeroSpace's hidden-workspace windows, parked so far into the corner
    // that their centers leave the display.
    private func focusTopUserWindow() {
        let display = Spaces.activeDisplayInfo()
        let displayBounds = Spaces.activeDisplayID().map(CGDisplayBounds)
        guard let window = CGWindows.real([.optionOnScreenOnly]).first(where: { window in
            guard NSRunningApplication(processIdentifier: window.pid)?.activationPolicy == .regular
            else { return false }
            guard let displayBounds else { return true }
            return displayBounds.contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        }) else { return }
        Log.write("chain: focus top window \(window.id) pid \(window.pid)")
        // Ranked explicitly: the makeKey's own focus event lands inside
        // the navigation suppression window and would go unrecorded.
        recency.noteFocus(windowID: window.id, source: "chain")
        Spaces.makeKey(pid: window.pid, windowID: window.id)
        // Arriving on a desktop can leave the top window's backing purged
        // (blank screen, healthy bookkeeping); a geometry nudge repaints it -
        // unless AeroSpace tiles this window, in which case its own arrival
        // re-tile repaints it and the nudge would only provoke a visible
        // relayout (the same "double blink" the switcher path avoids).
        if let display,
           aeroSpaceRepaintsOnArrival(aerospace, windowID: window.id,
                                      spaceID: display.current, display: display) {
            Log.debug("chain: nudge skipped: aerospace-tiled wid=\(window.id)")
        } else {
            AX.repaintNudge(pid: window.pid, windowID: window.id)
        }
    }
}
