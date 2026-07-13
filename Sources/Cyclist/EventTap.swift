import AppKit

// Session-level CGEventTap for keys (keyDown + flagsChanged), an active
// tap that can consume events. This is what lets Cyclist swallow Cmd+Tab
// before the Dock's native switcher sees it, and Ctrl+Arrows before
// Mission Control.
//
// The system disables a tap whose callback stalls; it re-enables itself
// and logs when that happens. Revoking Accessibility invalidates the tap
// port outright (the callback stops firing entirely), which is surfaced
// through onInvalidated so the owner can poll for the grant and call
// start() again - start() tears down the dead port and rebuilds.
final class EventTap {
    // The invalidation callback is a C function pointer and cannot capture;
    // a single live instance is all this app ever has.
    private static weak var current: EventTap?

    // Return true to consume the event.
    var onKeyDown: ((CGEvent) -> Bool)?
    var onFlagsChanged: ((CGEvent) -> Void)?
    var onInvalidated: (() -> Void)?

    private var keyTap: CFMachPort?

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
        return true
    }

    private func stop() {
        if let tap = keyTap {
            // Clear the callback first: a deliberate teardown must not look
            // like a revocation and re-trigger recovery.
            CFMachPortSetInvalidationCallBack(tap, nil)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)  // also removes its run-loop source
        }
        keyTap = nil
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
}
