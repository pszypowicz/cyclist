import AppKit

// Session-level CGEventTaps. Two separate taps:
//
// - Keys (keyDown + flagsChanged), an active tap that can consume events.
//   This is what lets Cyclist swallow Cmd+Tab before the Dock's native
//   switcher sees it, and Ctrl+Arrows before Mission Control.
// - Gestures (raw CGS gesture events, for the 3-finger swipe), a separate
//   LISTEN-ONLY tap: gesture events stream at input-device rate during any
//   touch, and a listen-only tap observes without delaying delivery - so
//   even a slow moment in touch processing can never stall the key tap and
//   make hotkeys "stop working".
//
// The system disables taps whose callback stalls; both re-enable themselves
// and log when that happens. Revoking Accessibility invalidates the tap
// ports outright (the callback stops firing entirely), which is surfaced
// through onInvalidated so the owner can poll for the grant and call
// start() again - start() tears down dead ports and rebuilds.
final class EventTap {
    // Raw CGS gesture events (trackpad touches) are not in the public
    // CGEventType enum.
    private static let gestureEventType: UInt32 = 29

    // The invalidation callback is a C function pointer and cannot capture;
    // a single live instance is all this app ever has.
    private static weak var current: EventTap?

    // Return true to consume the event.
    var onKeyDown: ((CGEvent) -> Bool)?
    var onFlagsChanged: ((CGEvent) -> Void)?
    var onGesture: ((CGEvent) -> Void)?
    var onInvalidated: (() -> Void)?

    private var keyTap: CFMachPort?
    private var gestureTap: CFMachPort?

    func start() -> Bool {
        if let keyTap, CFMachPortIsValid(keyTap) { return true }
        stop()
        Self.current = self

        let keyMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let keys = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(keyMask),
            callback: { _, type, event, refcon in
                let tap = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
                return tap.handleKey(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        keyTap = keys
        add(tap: keys)
        CFMachPortSetInvalidationCallBack(keys) { _, _ in
            Log.write("event tap: key tap invalidated")
            DispatchQueue.main.async { EventTap.current?.onInvalidated?() }
        }

        let gestureMask = CGEventMask(1) << Self.gestureEventType
        if let gestures = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: gestureMask,
            callback: { _, type, event, refcon in
                let tap = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
                return tap.handleGesture(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            gestureTap = gestures
            add(tap: gestures)
        } else {
            Log.write("event tap: gesture tap creation failed; 3-finger swipe disabled")
        }
        return true
    }

    private func stop() {
        for tap in [keyTap, gestureTap].compactMap({ $0 }) {
            // Clear the callback first: a deliberate teardown must not look
            // like a revocation and re-trigger recovery.
            CFMachPortSetInvalidationCallBack(tap, nil)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)  // also removes its run-loop source
        }
        keyTap = nil
        gestureTap = nil
    }

    private func add(tap: CFMachPort) {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.write("event tap: key tap disabled (\(type.rawValue)), re-enabling")
            if let keyTap {
                CGEvent.tapEnable(tap: keyTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            if onKeyDown?(event) == true {
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            onFlagsChanged?(event)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleGesture(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.write("event tap: gesture tap disabled (\(type.rawValue)), re-enabling")
            if let gestureTap {
                CGEvent.tapEnable(tap: gestureTap, enable: true)
            }
        default:
            if type.rawValue == Self.gestureEventType {
                onGesture?(event)
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
