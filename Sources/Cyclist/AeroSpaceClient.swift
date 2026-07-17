import AppKit

// Optional bridge to the AeroSpace tiling window manager. AeroSpace emulates
// workspaces inside a single native Space (windows of hidden workspaces are
// parked off-screen), which native Space bookkeeping cannot see. This client
// keeps an event-driven cache of AeroSpace's state so hot paths (a chain
// press, a switcher snapshot) read plain properties and never wait on the
// socket - a real AeroSpace command costs ~10ms on its main thread.
//
// The integration must be invisible when AeroSpace is not in play. Every
// lifecycle change is push-detected, so behavior reverts to native before
// the user's next keypress without polling:
//   - not installed / not running: the socket file is missing; one stat at
//     start(), then wait for the app-launch notification.
//   - "aerospace enable off": the server broadcasts a mode-changed event
//     with no mode to subscribers (it keeps subscriptions alive while
//     disabled); "enable on" broadcasts the new mode the same way.
//   - quit / killed / crashed: the kernel closes the socket, both
//     connections EOF, and one bounded reconnect cycle runs before giving
//     up until the next launch notification.
// The exit-code-2 "server is disabled" answer and kick() remain as backstops
// for a missed event; neither is the primary signal.
final class AeroSpaceClient {
    private static let bundleID = "bobko.aerospace"
    private static let subscribedEvents = [
        "mode-changed", "focused-workspace-changed", "focus-changed",
        "focused-monitor-changed", "window-detected",
    ]

    private let socketPath = "/tmp/\(AeroSpaceClient.bundleID)-\(NSUserName()).sock"

    private enum State: Equatable {
        case stopped     // integration toggled off
        case absent      // no server; waiting for the launch notification
        case connecting  // probe cycle in flight (bounded retries)
        case active      // connected, server enabled, cache live
        case disabled    // connected, but "aerospace enable off"
    }

    private var state: State = .stopped
    private var cmd: AeroSpaceConnection?
    private var events: AeroSpaceConnection?
    private var launchObservation: NSKeyValueObservation?
    private var retryWork: DispatchWorkItem?
    private var refreshWork: DispatchWorkItem?
    private var lastKick = Date.distantPast
    private var lastRefresh = Date.distantPast
    // Invalidates completions of a torn-down connection cycle.
    private var generation = 0
    private var loggedServer = false

    // MARK: - cache (readable any time; empty whenever not active)

    // Workspace names of AeroSpace's focused monitor, in AeroSpace's order,
    // filtered to workspaces that hold a window plus the focused one - the
    // ring should not walk empty workspaces the user never visits.
    private(set) var workspaces: [String] = []
    private(set) var focusedWorkspace: String?
    private var visibleWorkspaces: Set<String> = []
    private var windowWorkspace: [Int: String] = [:]

    var isActive: Bool { state == .active }

    // The workspace hiding this window, nil for windows AeroSpace does not
    // track or whose workspace is currently showing on some monitor.
    func hiddenWorkspace(forWindow id: Int) -> String? {
        guard let workspace = windowWorkspace[id] else { return nil }
        return visibleWorkspaces.contains(workspace) ? nil : workspace
    }

    // Value snapshot of the workspace caches for off-main sweeps; the live
    // dictionaries are main-thread-mutated and must not be read elsewhere.
    struct WorkspaceSnapshot {
        let windowWorkspace: [Int: String]
        let visibleWorkspaces: Set<String>

        // Same rule as hiddenWorkspace(forWindow:) on the live client.
        func hiddenWorkspace(forWindow id: Int) -> String? {
            guard let workspace = windowWorkspace[id] else { return nil }
            return visibleWorkspaces.contains(workspace) ? nil : workspace
        }
    }

    func workspaceSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(windowWorkspace: windowWorkspace, visibleWorkspaces: visibleWorkspaces)
    }

    // Window IDs AeroSpace assigns to a workspace, visible or hidden alike.
    func windowIDs(inWorkspace name: String) -> [Int] {
        windowWorkspace.compactMap { $0.value == name ? $0.key : nil }
    }

    // MARK: - lifecycle

    func start() {
        guard state == .stopped else { return }
        state = .absent
        if launchObservation == nil {
            // didLaunchApplicationNotification never fires for accessory
            // apps like AeroSpace, so watch the running-app list instead;
            // it changes for every launch. The connect retries absorb the
            // gap between the process appearing and its listener being up.
            launchObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] workspace, _ in
                DispatchQueue.main.async {
                    guard let self, self.state == .absent,
                          workspace.runningApplications.contains(where: {
                              $0.bundleIdentifier == Self.bundleID
                          }) else { return }
                    Log.write("aerospace: launched; connecting")
                    self.connect(attempt: 1)
                }
            }
        }
        if !connectIfSocketPresent() {
            Log.write("aerospace: socket absent; waiting for launch")
        }
    }

    func stop() {
        guard state != .stopped else { return }
        tearDown()
        state = .stopped
        launchObservation?.invalidate()
        launchObservation = nil
        Log.write("aerospace: integration stopped")
    }

    // MARK: - commands

    // failIfNoop makes a switch to the already-focused workspace answer
    // with a non-zero exit instead of a silent success, so callers that
    // chain focus work onto the switch can tell "switched" from "nothing
    // happened, nobody got focused".
    func switchToWorkspace(_ name: String, failIfNoop: Bool = false, completion: ((Bool) -> Void)? = nil) {
        var args = ["workspace", name]
        if failIfNoop {
            args.append("--fail-if-noop")
        }
        runCommand(args, what: "workspace \(name)", coalescingKey: "workspace",
                   quietFailure: failIfNoop,
                   onSuccess: { [weak self] in
                       // The confirming event may lag the answer; keep the
                       // cache ahead so an immediate next press steps from
                       // here.
                       self?.focusedWorkspace = name
                   },
                   completion: completion)
    }

    func focusWindow(_ windowID: Int, completion: ((Bool) -> Void)? = nil) {
        runCommand(["focus", "--window-id", String(windowID)], what: "focus \(windowID)",
                   completion: completion)
    }

    private func runCommand(_ args: [String],
                            what: String,
                            coalescingKey: String? = nil,
                            quietFailure: Bool = false,
                            onSuccess: (() -> Void)? = nil,
                            completion: ((Bool) -> Void)?) {
        guard state == .active, let cmd else {
            completion?(false)
            return
        }
        cmd.send(args: args, coalescingKey: coalescingKey) { [weak self] result in
            switch result {
            case .success(let answer) where answer.exitCode == 0:
                onSuccess?()
                completion?(true)
            case .success(let answer):
                self?.noteCommandError(what, answer, quiet: quietFailure)
                completion?(false)
            case .failure(let reason):
                Log.debug("aerospace: \(what) dropped (\(reason))")
                completion?(false)
            }
        }
    }

    // MARK: - freshness

    // Debounced full cache refresh; every subscription event funnels here,
    // so a burst of focus changes coalesces into a single refresh round.
    func refresh() {
        guard state == .active else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performRefresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // Backstop re-probe for a stranded state (a missed enable event, or a
    // connect cycle that gave up while the server lives on). Called from hot
    // paths, so it only ever schedules async work, at most once per 5s.
    func kick() {
        guard state == .absent || state == .disabled,
              Date().timeIntervalSince(lastKick) >= 5 else { return }
        lastKick = Date()
        switch state {
        case .absent:
            connectIfSocketPresent()
        case .disabled:
            cmd?.send(args: ["list-workspaces", "--focused"]) { [weak self] result in
                if case .success(let answer) = result, answer.exitCode == 0 {
                    Log.write("aerospace: enabled (probe)")
                    self?.becomeEnabled()
                }
            }
        default:
            break
        }
    }

    // MARK: - connection cycle

    private func connect(attempt: Int) {
        state = .connecting
        let generation = self.generation
        let cmd = AeroSpaceConnection(label: "cmd")
        let events = AeroSpaceConnection(label: "events")
        self.cmd = cmd
        self.events = events
        cmd.open(path: socketPath) { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case .failure(let error):
                self.openFailed(error, attempt: attempt)
            case .success:
                events.open(path: self.socketPath) { [weak self] result in
                    guard let self, self.generation == generation else { return }
                    switch result {
                    case .failure(let error):
                        self.openFailed(error, attempt: attempt)
                    case .success:
                        self.finishConnect(cmd: cmd, events: events)
                    }
                }
            }
        }
    }

    private func finishConnect(cmd: AeroSpaceConnection, events: AeroSpaceConnection) {
        let generation = self.generation
        cmd.onClosed = { [weak self] reason in self?.connectionLost(reason, generation: generation) }
        events.onClosed = { [weak self] reason in self?.connectionLost(reason, generation: generation) }
        // The subscription's initial push includes mode-changed, which
        // resolves .connecting into .active or .disabled - no probe command.
        events.subscribe(to: Self.subscribedEvents) { [weak self] event in
            guard let self, self.generation == generation else { return }
            self.handleEvent(event)
        }
        Log.write("aerospace: connected; awaiting initial state")
    }

    private func openFailed(_ error: AeroSpaceConnection.OpenError, attempt: Int) {
        tearDown()
        switch error {
        case .versionMismatch(let serverVersion):
            // Only an AeroSpace relaunch (with a compatible build) can
            // change this, and that fires the launch notification.
            Log.write("aerospace: protocol mismatch (server speaks v\(serverVersion),"
                + " this build v\(AeroSpaceConnection.protocolVersion)); staying native")
            state = .absent
        case .transport(let reason):
            guard attempt < 3 else {
                Log.write("aerospace: connect failed (\(reason)); waiting for launch")
                state = .absent
                return
            }
            state = .connecting
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.state == .connecting else { return }
                self.connect(attempt: attempt + 1)
            }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pow(3, Double(attempt - 1)), execute: work)
        }
    }

    private func connectionLost(_ reason: String, generation: Int) {
        guard self.generation == generation else { return }
        Log.write("aerospace: connection lost (\(reason))")
        tearDown()
        // A quit server leaves its socket file behind (it only unlinks on
        // startup), so a stat cannot distinguish quit from a transient drop;
        // one bounded retry cycle settles it either way.
        if !connectIfSocketPresent() {
            state = .absent
        }
    }

    @discardableResult
    private func connectIfSocketPresent() -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        connect(attempt: 1)
        return true
    }

    private func tearDown() {
        generation += 1
        retryWork?.cancel()
        retryWork = nil
        refreshWork?.cancel()
        refreshWork = nil
        cmd?.close()
        cmd = nil
        events?.close()
        events = nil
        loggedServer = false
        clearCache()
    }

    private func clearCache() {
        workspaces = []
        focusedWorkspace = nil
        visibleWorkspaces = []
        windowWorkspace = [:]
    }

    // MARK: - events

    private func handleEvent(_ event: [String: Any]) {
        guard let name = event["_event"] as? String else { return }
        Log.debug("aerospace event: \(name)"
            + (event["workspace"].map { " workspace=\($0)" } ?? "")
            + (event["mode"].map { " mode=\($0)" } ?? ""))
        switch name {
        case "mode-changed":
            // Any real mode means the server runs; no mode at all is the
            // "enable off" broadcast.
            if event["mode"] is String {
                becomeEnabled()
            } else {
                becomeDisabled()
            }
        case "focus-changed":
            // Fires on every window focus change systemwide; the payload
            // already carries the one thing focus can change (the focused
            // workspace), so a full re-query is only a slow-cadence
            // freshness sweep here, not the primary signal.
            if state == .active, let workspace = event["workspace"] as? String {
                focusedWorkspace = workspace
            }
            if Date().timeIntervalSince(lastRefresh) > 5 {
                refresh()
            }
        case "focused-workspace-changed", "focused-monitor-changed":
            if state == .active, let workspace = event["workspace"] as? String {
                focusedWorkspace = workspace
            }
            refresh()
        case "window-detected":
            refresh()
        default:
            break
        }
    }

    private func becomeEnabled() {
        guard state == .connecting || state == .disabled else { return }
        if state == .disabled {
            Log.write("aerospace: server enabled")
        }
        state = .active
        performRefresh()
    }

    private func becomeDisabled() {
        guard state == .connecting || state == .active else { return }
        Log.write("aerospace: server disabled; native behavior")
        state = .disabled
        refreshWork?.cancel()
        refreshWork = nil
        clearCache()
    }

    // MARK: - cache refresh

    private func performRefresh() {
        guard state == .active, let cmd else { return }
        let generation = self.generation
        // Two commands cover the whole cache: one workspace query with
        // format variables (ordering, focused flag, visibility, monitor
        // assignment in a single answer) and the window list. Commands
        // serialize on the connection and each holds AeroSpace's main
        // thread ~10ms, so fewer round trips matter.
        let queries: [[String]] = [
            ["list-workspaces", "--monitor", "all", "--json", "--format",
             "%{workspace} %{monitor-id} %{workspace-is-focused} %{workspace-is-visible}"],
            ["list-windows", "--monitor", "all", "--json", "--format", "%{window-id} %{workspace}"],
        ]
        var rows: [Int: [[String: Any]]] = [:]
        var pending = queries.count
        for (slot, args) in queries.enumerated() {
            cmd.send(args: args) { [weak self] result in
                guard let self, self.generation == generation else { return }
                pending -= 1
                switch result {
                case .success(let answer) where answer.exitCode == 0:
                    if !self.loggedServer {
                        self.loggedServer = true
                        Log.write("aerospace: server \(answer.serverVersion)")
                    }
                    if let data = answer.stdout.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        rows[slot] = parsed
                    }
                case .success(let answer):
                    self.noteCommandError("refresh", answer)
                case .failure(let reason):
                    Log.debug("aerospace: refresh query dropped (\(reason))")
                }
                if pending == 0 {
                    self.applyRefresh(rows)
                }
            }
        }
    }

    private func applyRefresh(_ rows: [Int: [[String: Any]]]) {
        guard state == .active else { return }
        guard let workspaceRows = rows[0], let windowRows = rows[1] else {
            Log.debug("aerospace: refresh incomplete")
            return
        }
        let focusedRow = workspaceRows.first { $0["workspace-is-focused"] as? Bool == true }
        let focused = focusedRow?["workspace"] as? String
        let focusedMonitor = focusedRow?["monitor-id"] as? Int
        let ordered = workspaceRows
            .filter { $0["monitor-id"] as? Int == focusedMonitor }
            .compactMap { $0["workspace"] as? String }
        let visible = Set(workspaceRows
            .filter { $0["workspace-is-visible"] as? Bool == true }
            .compactMap { $0["workspace"] as? String })
        var byWindow: [Int: String] = [:]
        for row in windowRows {
            guard let id = row["window-id"] as? Int,
                  let workspace = row["workspace"] as? String else { continue }
            byWindow[id] = workspace
        }
        let occupied = Set(byWindow.values)
        let merged = ordered.filter { occupied.contains($0) || $0 == focused }

        let changed = merged != workspaces || focused != focusedWorkspace
        workspaces = merged
        focusedWorkspace = focused
        visibleWorkspaces = visible
        windowWorkspace = byWindow
        lastRefresh = Date()
        let summary = "aerospace: cache workspaces=\(merged) focused=\(focused ?? "-")"
            + " visible=\(visible.sorted()) windows=\(byWindow.count)"
        if changed {
            Log.write(summary)
        } else {
            Log.debug(summary)
        }
    }

    private func noteCommandError(_ what: String, _ answer: AeroSpaceAnswer, quiet: Bool = false) {
        if answer.exitCode == 2, answer.stderr.contains("server is disabled") {
            becomeDisabled()
        } else if quiet {
            Log.debug("aerospace: \(what) failed (exit \(answer.exitCode)): \(answer.stderr)")
        } else {
            Log.write("aerospace: \(what) failed (exit \(answer.exitCode)): \(answer.stderr)")
        }
    }
}
