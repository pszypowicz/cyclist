import AppKit

// Session-level CGEventTap for keyDown and flagsChanged. This is what lets
// Cyclist swallow Cmd+Tab before the Dock's native switcher sees it.
final class EventTap {
    // Return true to consume the event.
    var onKeyDown: ((CGEvent) -> Bool)?
    var onFlagsChanged: ((CGEvent) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let eventTap = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
                return eventTap.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables taps whose callback stalls; re-arm or the
            // switcher silently dies.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
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
