import AppKit

// Session-level CGEventTaps, active taps that can consume events. The key
// tap (keyDown + flagsChanged) is what lets Cyclist swallow Cmd+Tab
// before the Dock's native switcher sees it, and Ctrl+Arrows before
// Mission Control. The gesture tap covers the CGS gesture stream (event
// types 29/30, outside the public CGEventType enum), where the
// WindowServer's recognized trackpad Spaces swipes travel to the Dock;
// consuming one there is what lets a real three-finger swipe drive chain
// navigation instead of the Dock's animated transition. The taps are
// separate ports so the untested churn of the gesture stream can never
// take keyboard handling down with it, and a system without tappable
// gesture events degrades to keys only.
//
// The system disables a tap whose callback stalls; each tap re-enables
// itself and logs when that happens. Revoking Accessibility invalidates
// the tap ports outright (the callbacks stop firing entirely), which is
// surfaced through onInvalidated so the owner can poll for the grant and
// call start() again - start() tears down the dead ports and rebuilds.
final class EventTap {
    // The invalidation callback is a C function pointer and cannot capture;
    // a single live instance is all this app ever has.
    private static weak var current: EventTap?

    // Return true to consume the event.
    var onKeyDown: ((CGEvent) -> Bool)?
    var onFlagsChanged: ((CGEvent) -> Void)?
    // Return true to consume the event. Called on the tap callback; real
    // work must be deferred off it.
    var onGesture: ((CGEvent) -> Bool)?
    var onInvalidated: (() -> Void)?

    private var keyTap: CFMachPort?
    private var gestureTap: CFMachPort?
    // Gesture-tap creation failing is remembered so a healthy key tap is
    // not torn down and rebuilt on every recovery poll.
    private var gestureTapUnsupported = false

    func start() -> Bool {
        if isRunning { return true }
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

        let gestureMask: CGEventMask = (1 << 29) | (1 << 30)
        if let gestures = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: gestureMask,
            callback: { _, type, event, refcon in
                let tap = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
                return tap.handleGesture(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            gestureTap = gestures
            gestureTapUnsupported = false
            add(tap: gestures)
            CFMachPortSetInvalidationCallBack(gestures) { _, _ in
                Log.write("event tap: gesture tap invalidated")
                DispatchQueue.main.async { EventTap.current?.onInvalidated?() }
            }
        } else {
            gestureTapUnsupported = true
            Log.write("event tap: gesture tap creation failed; trackpad swipes unavailable")
        }
        return true
    }

    private var isRunning: Bool {
        guard let keyTap, CFMachPortIsValid(keyTap) else { return false }
        if let gestureTap { return CFMachPortIsValid(gestureTap) }
        return gestureTapUnsupported
    }

    func stop() {
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
            return Unmanaged.passUnretained(event)
        default:
            if onGesture?(event) == true {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
    }
}
