import AppKit

// Private SkyLight/CoreGraphics symbols, the same ones AltTab and yabai rely
// on. Public APIs cannot report which Space a window belongs to, and Space
// membership is the only reliable way to separate a real window parked in
// another Space from the invisible bookkeeping windows many apps keep alive
// after their last real window closes.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

// SLS symbols live in the private SkyLight framework, which cannot be linked
// against (no on-disk stub); AppKit loads it into every GUI process, so the
// symbol is resolved at runtime instead.
private typealias SLSCopyWindowsWithOptionsAndTagsFn = @convention(c) (
    UInt32, UInt32, CFArray, UInt32,
    UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
) -> Unmanaged<CFArray>?

private func resolve<T>(_ name: String, as type: T.Type) -> T? {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, name) else { return nil }
    return unsafeBitCast(symbol, to: type)
}

private let SLSCopyWindowsWithOptionsAndTags =
    resolve("SLSCopyWindowsWithOptionsAndTags", as: SLSCopyWindowsWithOptionsAndTagsFn.self)

private typealias SLPSSetFrontProcessFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32
) -> Int32
private typealias SLPSPostEventRecordToFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
) -> Int32
private typealias GetProcessForPIDFn = @convention(c) (
    pid_t, UnsafeMutablePointer<ProcessSerialNumber>
) -> Int32

private let SLPSSetFrontProcessWithOptions =
    resolve("_SLPSSetFrontProcessWithOptions", as: SLPSSetFrontProcessFn.self)
private let SLPSPostEventRecordTo =
    resolve("SLPSPostEventRecordTo", as: SLPSPostEventRecordToFn.self)
private let GetProcessForPIDFallback =
    resolve("GetProcessForPID", as: GetProcessForPIDFn.self)

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> Unmanaged<CFArray>?

enum Spaces {
    // Window IDs actually present in each Space that exists but is not
    // currently shown on any display. The per-Space window list is the
    // authority here: CGSCopySpacesForWindows keeps reporting a stale Space
    // assignment for the dead window an app caches after its last real
    // window closes, while the Space's own window list drops it immediately.
    static func windowsByNonVisibleSpace() -> [UInt64: Set<Int>] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
            .takeRetainedValue() as? [[String: Any]] else { return [:] }
        var result: [UInt64: Set<Int>] = [:]
        for display in displays {
            let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
            for space in (display["Spaces"] as? [[String: Any]]) ?? [] {
                guard let id = space["id64"] as? UInt64, id != current else { continue }
                result[id] = windowIDs(inSpace: id)
            }
        }
        return result
    }

    // Make a specific window key through the WindowServer: front the process
    // with the target window, then post a synthetic left mouse down/up pair
    // addressed to the window by id, aimed just outside its frame so nothing
    // is actually clicked. Activating the app alone cannot do this (macOS 14
    // downgraded NSRunningApplication.activate to an advisory request), and
    // without a key window the menu bar keeps naming the previous app.
    // The record layout follows CGSInternal's CGSEvent.h as used by AltTab
    // and yabai: 0x04 record length, 0x08 event type, 0x20 window-relative
    // click point, 0x3a undocumented flag, 0x3c target window id. The buffer
    // is 0x100 although the record says 0xf8: the WindowServer reads past
    // the record on macOS 14.7.4+ and crashes on a tight allocation.
    static func makeKey(pid: pid_t, windowID: Int) {
        guard let setFront = SLPSSetFrontProcessWithOptions,
              let postEvent = SLPSPostEventRecordTo,
              let getPSN = GetProcessForPIDFallback else {
            Log.write("makeKey: symbol resolution failed")
            return
        }
        var psn = ProcessSerialNumber()
        let psnErr = getPSN(pid, &psn)
        guard psnErr == 0 else {
            Log.write("makeKey: GetProcessForPID(\(pid)) failed: \(psnErr)")
            return
        }
        var wid = UInt32(windowID)
        let frontErr = setFront(&psn, wid, 0x200)  // kCPSUserGenerated
        Log.write("makeKey: pid=\(pid) wid=\(wid) setFront=\(frontErr)")
        var point = CGPoint(x: -1, y: -1)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
        memcpy(&bytes[0x20], &point, MemoryLayout<CGPoint>.size)
        bytes[0x08] = 0x01  // kCGEventLeftMouseDown
        _ = postEvent(&psn, &bytes)
        bytes[0x08] = 0x02  // kCGEventLeftMouseUp
        _ = postEvent(&psn, &bytes)
    }

    // Space order, types, and current Space of the primary display.
    static func mainDisplayInfo() -> (order: [UInt64], types: [UInt64: Int], current: UInt64)? {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
            .takeRetainedValue() as? [[String: Any]],
              let display = displays.first,
              let spaces = display["Spaces"] as? [[String: Any]],
              let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
        else { return nil }
        var order: [UInt64] = []
        var types: [UInt64: Int] = [:]
        for space in spaces {
            if let id = space["id64"] as? UInt64 {
                order.append(id)
                types[id] = space["type"] as? Int ?? -1
            }
        }
        return (order, types, current)
    }

    static func windowIDs(inSpace spaceID: UInt64) -> Set<Int> {
        guard let copyWindows = SLSCopyWindowsWithOptionsAndTags else { return [] }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let list = copyWindows(
            CGSMainConnectionID(), 0, [NSNumber(value: spaceID)] as CFArray, 0x2, &setTags, &clearTags
        )?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(list.map { $0.intValue })
    }

    // NOTE: never drive the Space state itself (CGSManagedDisplaySetCurrentSpace,
    // SLSShowSpaces/SLSHideSpaces) from here. Those flip WindowServer
    // bookkeeping without the Mission Control choreography: the old Space
    // keeps compositing underneath the new one, and once desynchronized even
    // native transitions stop working until the WindowServer state resets.

    static let fullscreenSpaceType = 4

    // Space order, per-Space types, and current Space of the display
    // containing the given Space, for step-by-step navigation.
    static func orderInfo(containing spaceID: UInt64)
        -> (order: [UInt64], types: [UInt64: Int], current: UInt64)? {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]],
                  let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
            else { continue }
            let ids = spaces.compactMap { $0["id64"] as? UInt64 }
            guard ids.contains(spaceID) else { continue }
            var types: [UInt64: Int] = [:]
            for space in spaces {
                if let id = space["id64"] as? UInt64, let type = space["type"] as? Int {
                    types[id] = type
                }
            }
            return (ids, types, current)
        }
        return nil
    }

    // Instant Space switch: synthetic trackpad dock-swipe gestures with
    // high velocity, so the Dock switches with no animation (~40ms
    // observed). Undocumented CGEvent field indices posted through the
    // public CGEventPost; the exact encoding follows Space Rabbit
    // (github.com/Tahul/space-rabbit): direction as a plain 0/1 integer in
    // the flag-bits field, Began+Ended phases only, progress and velocity
    // on Ended, and one gesture pair per step with velocity scaled by the
    // step count. Unlike the iss/Spaceman float-bit-pattern encoding, this
    // shape also switches between two fullscreen Spaces and chains
    // multi-step jumps with no delay.
    static func postDockSwipes(right: Bool, steps: Int) {
        let eventTypeField = CGEventField(rawValue: 55)!       // real CGS event type
        let gestureHIDTypeField = CGEventField(rawValue: 110)! // IOHIDEventType
        let scrollYField = CGEventField(rawValue: 119)!
        let swipeMotionField = CGEventField(rawValue: 123)!
        let swipeProgressField = CGEventField(rawValue: 124)!
        let swipeVelocityXField = CGEventField(rawValue: 129)!
        let swipeVelocityYField = CGEventField(rawValue: 130)!
        let gesturePhaseField = CGEventField(rawValue: 132)!
        let flagBitsField = CGEventField(rawValue: 135)!
        let zoomDeltaXField = CGEventField(rawValue: 139)!

        let count = max(1, steps)
        let flagDirection: Int64 = right ? 1 : 0
        let progress = right ? 2.0 : -2.0
        let velocity = (right ? 400.0 : -400.0) * Double(count)

        func postPair(phase: Int64) {
            guard let dockEvent = CGEvent(source: nil),
                  let gestureEvent = CGEvent(source: nil) else { return }
            dockEvent.setIntegerValueField(eventTypeField, value: 30)      // DockControl
            dockEvent.setIntegerValueField(gestureHIDTypeField, value: 23) // dock swipe
            dockEvent.setIntegerValueField(gesturePhaseField, value: phase)
            dockEvent.setIntegerValueField(flagBitsField, value: flagDirection)
            dockEvent.setIntegerValueField(swipeMotionField, value: 1)     // horizontal
            dockEvent.setDoubleValueField(scrollYField, value: 0)
            // A zero zoom delta makes the Dock discard the event as a no-op.
            dockEvent.setDoubleValueField(zoomDeltaXField, value: Double(Float.leastNonzeroMagnitude))
            if phase == 4 {  // ended: the phase where the Dock decides to snap
                dockEvent.setDoubleValueField(swipeProgressField, value: progress)
                dockEvent.setDoubleValueField(swipeVelocityXField, value: velocity)
                dockEvent.setDoubleValueField(swipeVelocityYField, value: 0)
            }
            gestureEvent.setIntegerValueField(eventTypeField, value: 29)   // gesture envelope
            dockEvent.post(tap: .cgSessionEventTap)
            gestureEvent.post(tap: .cgSessionEventTap)
        }

        for _ in 0..<count {
            postPair(phase: 1)  // began
            postPair(phase: 4)  // ended
        }
    }

}
