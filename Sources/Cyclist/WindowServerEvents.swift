import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

// The per-connection notification callback: (event id, payload, payload
// length, context, connection id). The WindowServer invokes it on whichever
// thread receives the datagram; the payload pointer is only valid during
// the call, so the integers are extracted synchronously and the rest hops
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

// Force-unwrapped: the app targets the macOS version it runs on, and
// without the notification stream there is nothing useful it could do.
private func resolve<T>(_ name: String, as type: T.Type) -> T {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    return unsafeBitCast(dlsym(rtldDefault, name)!, to: type)
}

private let SLSRegisterConnectionNotifyProc =
    resolve("SLSRegisterConnectionNotifyProc", as: RegisterConnectionNotifyProcFn.self)
private let SLSRequestNotificationsForWindows =
    resolve("SLSRequestNotificationsForWindows", as: RequestNotificationsForWindowsFn.self)

// The C callback cannot capture; the stream is recovered through the
// context pointer. Safe because the stream is owned for the process
// lifetime and registrations are never torn down. Window events carry the
// window id in the first 4 payload bytes; Space events carry the space id
// in the first 8.
private let notifyProc: ConnectionNotifyProc = { event, data, length, context, _ in
    guard let context else { return }
    var windowID: UInt32 = 0
    var spaceID: UInt64 = 0
    if let data, length >= 4 {
        memcpy(&windowID, data, 4)
    }
    if let data, length >= 8 {
        memcpy(&spaceID, data, 8)
    }
    let stream = Unmanaged<WindowServerEvents>.fromOpaque(context).takeUnretainedValue()
    if Thread.isMainThread {
        stream.handle(event: event, windowID: windowID, spaceID: spaceID)
    } else {
        DispatchQueue.main.async { stream.handle(event: event, windowID: windowID, spaceID: spaceID) }
    }
}

// Window focus and Space change events straight from the WindowServer's
// notification stream, the signal AltTab migrated to after years of
// Accessibility-notification bugs: the window server announces every real
// focus change no matter how busy the app is or how broken its AX tree may
// be, and announces Space changes the moment its bookkeeping flips instead
// of whenever AppKit relays them. Window-event delivery requires opting the
// connection into per-window notifications, so the opted-in set tracks
// window lifecycle via the create/destroy events on the same stream; Space
// events are connection-wide.
final class WindowServerEvents {
    // WindowServer event ids (SkyLight, stable since macOS 10.10; the same
    // values AltTab and yabai use).
    private static let windowDestroyed: UInt32 = 804
    private static let windowFocused: UInt32 = 808
    private static let windowCreated: UInt32 = 811
    private static let spaceCurrentChanged: UInt32 = 1329
    private static let activeSpaceChanged: UInt32 = 1401

    // All fire on the main queue. Space changes arrive as a burst per
    // transition and can fire mid-animation; consumers must treat them as
    // wake-up hints and re-read real state, never as arrival truth.
    var onFocused: ((Int) -> Void)?
    var onCreated: ((Int) -> Void)?
    var onDestroyed: ((Int) -> Void)?
    var onSpaceChanged: ((UInt64) -> Void)?

    private var optedIn: Set<UInt32> = []
    private var pushPending = false

    // Registers the notify procs and seeds the opt-in set.
    func start() {
        let cid = CGSMainConnectionID()
        let context = Unmanaged.passUnretained(self).toOpaque()
        for event in [Self.windowFocused, Self.windowCreated, Self.windowDestroyed,
                      Self.spaceCurrentChanged, Self.activeSpaceChanged] {
            _ = SLSRegisterConnectionNotifyProc(cid, notifyProc, event, context)
        }
        // Seed with every real window on every Space: other-Space windows
        // (native fullscreen included) never appear in on-screen lists but
        // must deliver their focus events when the user lands on them.
        for window in CGWindows.real([.optionAll, .excludeDesktopElements]) {
            optedIn.insert(UInt32(window.id))
        }
        pushOptIns()
        Log.write("wsevents: stream active, \(optedIn.count) windows opted in")
    }

    fileprivate func handle(event: UInt32, windowID: UInt32, spaceID: UInt64) {
        switch event {
        case Self.windowFocused:
            onFocused?(Int(windowID))
        case Self.windowCreated:
            if optedIn.insert(windowID).inserted {
                schedulePushOptIns()
            }
            onCreated?(Int(windowID))
        case Self.windowDestroyed:
            if optedIn.remove(windowID) != nil {
                schedulePushOptIns()
            }
            onDestroyed?(Int(windowID))
        case Self.spaceCurrentChanged, Self.activeSpaceChanged:
            onSpaceChanged?(spaceID)
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
        guard !optedIn.isEmpty else { return }
        var list = Array(optedIn)
        _ = SLSRequestNotificationsForWindows(CGSMainConnectionID(), &list, Int32(list.count))
    }
}
