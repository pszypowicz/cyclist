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
// with the workspace switch chained onto the verified arrival. When the
// client is inactive the ring, base, and arrival behavior are exactly the
// native code path.
final class ChainNavigator {
    private let navigator: SpaceNavigator
    private let aerospace: AeroSpaceClient

    private enum RingElement: Equatable {
        case native(UInt64)
        case workspace(String, host: UInt64)
    }

    // A direct workspace switch answers in ~10-30ms; past that the press
    // was lost and the next one should re-read reality. The two-hop grace
    // covers the paced native leg (retries included) before the switch
    // can even be issued.
    private let directSwitchGrace: TimeInterval = 0.3
    private let hopSwitchGrace: TimeInterval = 3.0

    // The in-flight workspace destination. AeroSpace steps never go
    // through SpaceNavigator, so the chain keeps its own pending notion
    // for the same reason SpaceNavigator has pendingTarget: rapid presses
    // must chain from where navigation is already headed, not from the
    // (stale) focused workspace.
    private var pendingWorkspace: (name: String, host: UInt64, expires: Date)?

    init(navigator: SpaceNavigator, aerospace: AeroSpaceClient) {
        self.navigator = navigator
        self.aerospace = aerospace
    }

    func navigate(left: Bool) {
        guard let display = Spaces.activeDisplayInfo() else {
            Log.write("chain: no display info")
            return
        }
        // Self-heal a stranded client (missed enable event, exhausted
        // reconnect); async and debounced, never affects this press.
        aerospace.kick()
        guard let (ring, base) = resolveRing(display) else {
            Log.write("chain: current position not in ring")
            return
        }
        guard let currentIndex = ring.firstIndex(of: base) else { return }
        let targetIndex = currentIndex + (left ? -1 : 1)
        guard ring.indices.contains(targetIndex) else {
            Log.write("chain: at \(left ? "left" : "right") edge")
            return
        }
        let direction = left ? "left" : "right"

        switch ring[targetIndex] {
        case .native(let id):
            pendingWorkspace = nil
            Log.write("chain: \(direction) \(describe(base)) -> space \(id)")
            let arrival: (() -> Void)? = display.types[id] == 0
                ? { Self.focusTopUserWindow() }
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
                self.aerospace.switchToWorkspace(target) { [weak self] ok in
                    guard let self, self.pendingWorkspace?.name == target else { return }
                    self.pendingWorkspace = nil
                    if !ok {
                        // Keep the fullscreen-exit guarantee of landing on
                        // something concrete even if the client just died.
                        Log.write("chain: workspace switch to \(target) failed after hop")
                        Self.focusTopUserWindow()
                    }
                }
            })
            if !started {
                pendingWorkspace = nil
            }
        }
    }

    // MARK: - ring construction

    private typealias DisplayInfo = (order: [UInt64], types: [UInt64: Int], current: UInt64)

    private func resolveRing(_ display: DisplayInfo) -> ([RingElement], RingElement)? {
        // A mid-refresh cache (focused workspace not in the list yet)
        // degrades this press to a pure native step rather than guessing.
        if let host = chooseHost(display), let resolved = ringAndBase(display, host: host) {
            return resolved
        }
        return ringAndBase(display, host: nil)
    }

    private func ringAndBase(_ display: DisplayInfo, host: UInt64?) -> ([RingElement], RingElement)? {
        let ring = buildRing(display, host: host)
        guard let base = baseElement(display, ring: ring, host: host) else { return nil }
        return (ring, base)
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
        return display.order.flatMap { id -> [RingElement] in
            guard id == host else { return [.native(id)] }
            return aerospace.workspaces.map { .workspace($0, host: host) }
        }
    }

    // Where this press steps from: the in-flight workspace switch, then
    // the in-flight native hop, then the real current position.
    private func baseElement(_ display: DisplayInfo, ring: [RingElement], host: UInt64?) -> RingElement? {
        if let pending = pendingWorkspace, pending.expires > Date() {
            let element = RingElement.workspace(pending.name, host: pending.host)
            if ring.contains(element) { return element }
        }
        if let inFlight = navigator.pendingTarget {
            if inFlight == host {
                // The hop lands on the host desktop, which shows its
                // focused workspace.
                guard let focused = aerospace.focusedWorkspace,
                      ring.contains(.workspace(focused, host: inFlight)) else { return nil }
                return .workspace(focused, host: inFlight)
            }
            if ring.contains(.native(inFlight)) { return .native(inFlight) }
        }
        if display.current == host {
            guard let focused = aerospace.focusedWorkspace,
                  ring.contains(.workspace(focused, host: display.current)) else { return nil }
            return .workspace(focused, host: display.current)
        }
        if ring.contains(.native(display.current)) { return .native(display.current) }
        return nil
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
    private static func focusTopUserWindow() {
        let displayBounds = Spaces.activeDisplayID().map(CGDisplayBounds)
        guard let window = CGWindows.real([.optionOnScreenOnly]).first(where: { window in
            guard NSRunningApplication(processIdentifier: window.pid)?.activationPolicy == .regular
            else { return false }
            guard let displayBounds else { return true }
            return displayBounds.contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        }) else { return }
        Log.write("chain: focus top window \(window.id) pid \(window.pid)")
        Spaces.makeKey(pid: window.pid, windowID: window.id)
    }
}
