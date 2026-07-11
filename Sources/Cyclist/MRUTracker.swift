import AppKit

// Most-recently-used ordering of running apps, driven by activation
// notifications. Position 0 is the frontmost app, position 1 the app a quick
// Cmd+Tab should switch back to.
final class MRUTracker {
    private(set) var order: [pid_t] = []

    init() {
        if let front = NSWorkspace.shared.frontmostApplication {
            order.append(front.processIdentifier)
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if !order.contains(app.processIdentifier) {
                order.append(app.processIdentifier)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(didActivate(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(didTerminate(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func position(of pid: pid_t) -> Int {
        order.firstIndex(of: pid) ?? Int.max
    }

    @objc private func didActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        order.removeAll { $0 == app.processIdentifier }
        order.insert(app.processIdentifier, at: 0)
        // By activation time the app's windows are AX-visible even when the
        // activation came from arriving in a fullscreen Space, where the
        // navigator's own arrival harvest still races AX exposure. Only the
        // activated app is swept: this runs on the main thread on every app
        // switch, and a full-Space sweep here could stall the run loop that
        // services the key tap (the full sweep stays on Space arrival).
        AppListProvider.harvestTitles(pids: [app.processIdentifier])
    }

    @objc private func didTerminate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        order.removeAll { $0 == app.processIdentifier }
    }
}
