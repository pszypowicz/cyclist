import AppKit

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

// The per-connection notification callback: (event id, payload, payload
// length, context, connection id). The WindowServer invokes it on whichever
// thread receives the datagram; the payload pointer is only valid during
// the call, so the window id is extracted synchronously and the rest hops
// to the main queue.
private typealias ConnectionNotifyProc = @convention(c) (
    UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?, UInt32
) -> Void

private typealias RegisterConnectionNotifyProcFn = @convention(c) (
    UInt32, ConnectionNotifyProc, UInt32, UnsafeMutableRawPointer?
) -> CGError
private typealias RequestNotificationsForWindowsFn = @convention(c) (
    UInt32, UnsafeMutablePointer<UInt32>, Int32
) -> CGError

private func resolve<T>(_ name: String, as type: T.Type) -> T? {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

private let SLSRegisterConnectionNotifyProc =
    resolve("SLSRegisterConnectionNotifyProc", as: RegisterConnectionNotifyProcFn.self)
private let SLSRequestNotificationsForWindows =
    resolve("SLSRequestNotificationsForWindows", as: RequestNotificationsForWindowsFn.self)

// The C callback cannot capture; the stream is recovered through the
// context pointer. Safe because the stream is owned for the process
// lifetime and registrations are never torn down.
private let notifyProc: ConnectionNotifyProc = { event, data, length, context, _ in
    guard let context else { return }
    var windowID: UInt32 = 0
    if let data, length >= 4 {
        memcpy(&windowID, data, 4)
    }
    let stream = Unmanaged<WindowServerFocus>.fromOpaque(context).takeUnretainedValue()
    if Thread.isMainThread {
        stream.handle(event: event, windowID: windowID)
    } else {
        DispatchQueue.main.async { stream.handle(event: event, windowID: windowID) }
    }
}

// Window focus events straight from the WindowServer's notification stream,
// the signal AltTab migrated to after years of Accessibility-notification
// bugs: the window server announces every real focus change regardless of
// how busy the app is or how broken its AX tree may be. Delivery requires
// opting the connection into per-window notifications, so the opted-in set
// tracks window lifecycle via the create/destroy events on the same stream.
final class WindowServerFocus {
    // WindowServer event ids (SkyLight, stable since macOS 10.10; the same
    // values AltTab and yabai use).
    private static let windowDestroyed: UInt32 = 804
    private static let windowFocused: UInt32 = 808
    private static let windowCreated: UInt32 = 811

    // Both fire on the main queue.
    var onFocused: ((Int) -> Void)?
    var onDestroyed: ((Int) -> Void)?

    private var optedIn: Set<UInt32> = []
    private var pushPending = false

    // Registers the notify procs and seeds the opt-in set. Returns false
    // when the SkyLight symbols are missing (a future macOS could remove
    // them); recency then degrades to commit recording plus the z-order
    // seed instead of breaking.
    func start() -> Bool {
        guard let register = SLSRegisterConnectionNotifyProc,
              SLSRequestNotificationsForWindows != nil else {
            Log.write("wsfocus: SkyLight notify symbols missing; focus events unavailable")
            return false
        }
        let cid = CGSMainConnectionID()
        let context = Unmanaged.passUnretained(self).toOpaque()
        for event in [Self.windowFocused, Self.windowCreated, Self.windowDestroyed] {
            _ = register(cid, notifyProc, event, context)
        }
        // Seed with every real window on every Space: other-Space windows
        // (native fullscreen included) never appear in on-screen lists but
        // must deliver their focus events when the user lands on them.
        for window in CGWindows.real([.optionAll, .excludeDesktopElements]) {
            optedIn.insert(UInt32(window.id))
        }
        pushOptIns()
        Log.write("wsfocus: stream active, \(optedIn.count) windows opted in")
        return true
    }

    fileprivate func handle(event: UInt32, windowID: UInt32) {
        switch event {
        case Self.windowFocused:
            onFocused?(Int(windowID))
        case Self.windowCreated:
            if optedIn.insert(windowID).inserted {
                schedulePushOptIns()
            }
        case Self.windowDestroyed:
            if optedIn.remove(windowID) != nil {
                schedulePushOptIns()
            }
            onDestroyed?(Int(windowID))
        default:
            break
        }
    }

    // The request replaces the connection's whole list each call, and Space
    // transitions emit creation bursts; coalesce to one push per tick.
    private func schedulePushOptIns() {
        guard !pushPending else { return }
        pushPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pushPending = false
            self.pushOptIns()
        }
    }

    private func pushOptIns() {
        guard let request = SLSRequestNotificationsForWindows, !optedIn.isEmpty else { return }
        var list = Array(optedIn)
        _ = request(CGSMainConnectionID(), &list, Int32(list.count))
    }
}
