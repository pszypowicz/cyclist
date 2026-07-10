import AppKit

// Ctrl+Left/Right and 3-finger-swipe navigation over an ordered chain:
// AeroSpace workspaces on the primary display first (those with at least
// one window in the current user Space, sorted numerically, plus the
// focused workspace even when empty so closing the last window does not
// strand navigation), then native fullscreen Spaces. Ported from the
// Hammerspoon implementation it replaces, with Space hops going through
// SpaceNavigator's instant gestures instead of Mission Control.
//
// Workspace entries are reached by focusing a concrete window that lives
// in the user Space rather than running `aerospace workspace`: the bare
// switch MRU-picks any fullscreen sibling in the workspace (e.g. a Safari
// video) and drags macOS into its Space. AeroSpace follows window focus,
// so making the window key is all a workspace switch needs.
final class ChainNavigator {
    private enum Entry: Equatable {
        case workspace(id: String, windowID: Int?, pid: pid_t?)
        case anchor(spaceID: UInt64)      // the user Space, when AeroSpace is absent
        case fullscreen(spaceID: UInt64)
    }

    private let navigator: SpaceNavigator

    init(navigator: SpaceNavigator) {
        self.navigator = navigator
    }

    func navigate(left: Bool) {
        guard let display = Spaces.mainDisplayInfo() else { return }
        let chain = buildChain(display: display)
        guard let index = currentIndex(in: chain, display: display) else { return }
        let targetIndex = index + (left ? -1 : 1)
        guard chain.indices.contains(targetIndex) else { return }
        go(to: chain[targetIndex], display: display)
    }

    private func userSpace(in display: (order: [UInt64], types: [UInt64: Int], current: UInt64)) -> UInt64? {
        display.order.first { display.types[$0] == 0 }
    }

    private func buildChain(display: (order: [UInt64], types: [UInt64: Int], current: UInt64)) -> [Entry] {
        var chain: [Entry] = []
        let userSpaceID = userSpace(in: display)
        if let workspaces = aerospaceEntries(userSpaceID: userSpaceID) {
            chain.append(contentsOf: workspaces)
        } else if let userSpaceID {
            chain.append(.anchor(spaceID: userSpaceID))
        }
        for spaceID in display.order where display.types[spaceID] == Spaces.fullscreenSpaceType {
            chain.append(.fullscreen(spaceID: spaceID))
        }
        return chain
    }

    private func aerospaceEntries(userSpaceID: UInt64?) -> [Entry]? {
        guard let monitorList = Aerospace.run(["list-workspaces", "--monitor", "focused"]),
              let windowList = Aerospace.run(
                ["list-windows", "--all", "--format", "%{workspace} %{window-id} %{app-pid}"])
        else { return nil }

        let userWindowIDs = userSpaceID.map { Spaces.windowIDs(inSpace: $0) } ?? []
        var firstWindow: [String: (windowID: Int, pid: pid_t)] = [:]
        for line in windowList.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 3,
                  let windowID = Int(parts[1]), let pid = pid_t(parts[2]),
                  userWindowIDs.contains(windowID) else { continue }
            let workspace = String(parts[0])
            if firstWindow[workspace] == nil {
                firstWindow[workspace] = (windowID, pid)
            }
        }

        var names = monitorList.split(separator: "\n").map(String.init)
            .filter { firstWindow[$0] != nil }
        if let focused = Aerospace.run(["list-workspaces", "--focused"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !focused.isEmpty, !names.contains(focused) {
            names.append(focused)
        }
        names.sort { (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1) }
        return names.map {
            .workspace(id: $0, windowID: firstWindow[$0]?.windowID, pid: firstWindow[$0]?.pid)
        }
    }

    private func currentIndex(
        in chain: [Entry],
        display: (order: [UInt64], types: [UInt64: Int], current: UInt64)
    ) -> Int? {
        if display.types[display.current] == Spaces.fullscreenSpaceType {
            return chain.firstIndex(of: .fullscreen(spaceID: display.current))
        }
        if let anchorIndex = chain.firstIndex(of: .anchor(spaceID: display.current)) {
            return anchorIndex
        }
        guard let focused = Aerospace.run(["list-workspaces", "--focused"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !focused.isEmpty else { return nil }
        return chain.firstIndex { entry in
            if case .workspace(let id, _, _) = entry { return id == focused }
            return false
        }
    }

    private func go(
        to entry: Entry,
        display: (order: [UInt64], types: [UInt64: Int], current: UInt64)
    ) {
        switch entry {
        case .fullscreen(let spaceID), .anchor(let spaceID):
            Log.write("chain: goto space \(spaceID)")
            _ = navigator.begin(to: spaceID, focusPid: 0, windowID: nil)
        case .workspace(let id, let windowID, let pid):
            let inFullscreen = display.types[display.current] == Spaces.fullscreenSpaceType
            if let windowID, let pid {
                if inFullscreen, let userSpaceID = userSpace(in: display) {
                    Log.write("chain: leave fullscreen, focus workspace \(id) window \(windowID)")
                    _ = navigator.begin(to: userSpaceID, focusPid: pid, windowID: windowID)
                } else {
                    Log.write("chain: focus workspace \(id) window \(windowID)")
                    Spaces.makeKey(pid: pid, windowID: windowID)
                }
            } else if !inFullscreen {
                // Empty workspace: nothing to focus, let AeroSpace switch.
                Log.write("chain: switch to empty workspace \(id)")
                _ = Aerospace.run(["workspace", id])
            }
        }
    }
}
