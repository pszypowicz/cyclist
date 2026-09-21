import ApplicationServices
import Foundation

// Private SkyLight/CoreGraphics symbols, the same ones AltTab and yabai rely
// on. Public APIs cannot report which Space a window belongs to, and Space
// membership is the only reliable way to separate a real window parked in
// another Space from the invisible bookkeeping windows many apps keep alive
// after their last real window closes.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

// SLS symbols live in the private SkyLight framework, which cannot be linked
// against (no on-disk stub); AppKit loads it into every GUI process, so the
// symbol is resolved at runtime instead. Resolution is force-unwrapped: the
// app targets the macOS version it runs on, and without these symbols there
// is nothing useful it could do.
private typealias SLSCopyWindowsWithOptionsAndTagsFn = @convention(c) (
    UInt32, UInt32, CFArray, UInt32,
    UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
) -> Unmanaged<CFArray>?

private func resolve<T>(_ name: String, as type: T.Type) -> T {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    return unsafeBitCast(dlsym(rtldDefault, name)!, to: type)
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

private typealias SLSCopyActiveMenuBarDisplayIdentifierFn = @convention(c) (UInt32) -> Unmanaged<CFString>?
private let SLSCopyActiveMenuBarDisplayIdentifier =
    resolve("SLSCopyActiveMenuBarDisplayIdentifier", as: SLSCopyActiveMenuBarDisplayIdentifierFn.self)

private let SLPSSetFrontProcessWithOptions =
    resolve("_SLPSSetFrontProcessWithOptions", as: SLPSSetFrontProcessFn.self)
private let SLPSPostEventRecordTo =
    resolve("SLPSPostEventRecordTo", as: SLPSPostEventRecordToFn.self)
private let GetProcessForPIDFallback =
    resolve("GetProcessForPID", as: GetProcessForPIDFn.self)

// One IPC returning a snapshot of the requested windows; the iterator
// getters read that local snapshot without further round trips.
private typealias SLSWindowQueryWindowsFn = @convention(c) (UInt32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
private typealias SLSWindowQueryResultCopyWindowsFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
private typealias SLSWindowIteratorAdvanceFn = @convention(c) (CFTypeRef) -> Bool
private typealias SLSWindowIteratorGetWindowIDFn = @convention(c) (CFTypeRef) -> UInt32
private typealias SLSWindowIteratorGetAttributesFn = @convention(c) (CFTypeRef) -> UInt64
private typealias SLSWindowIteratorGetTagsFn = @convention(c) (CFTypeRef) -> UInt64

private let SLSWindowQueryWindows =
    resolve("SLSWindowQueryWindows", as: SLSWindowQueryWindowsFn.self)
private let SLSWindowQueryResultCopyWindows =
    resolve("SLSWindowQueryResultCopyWindows", as: SLSWindowQueryResultCopyWindowsFn.self)
private let SLSWindowIteratorAdvance =
    resolve("SLSWindowIteratorAdvance", as: SLSWindowIteratorAdvanceFn.self)
private let SLSWindowIteratorGetWindowID =
    resolve("SLSWindowIteratorGetWindowID", as: SLSWindowIteratorGetWindowIDFn.self)
private let SLSWindowIteratorGetAttributes =
    resolve("SLSWindowIteratorGetAttributes", as: SLSWindowIteratorGetAttributesFn.self)
private let SLSWindowIteratorGetTags =
    resolve("SLSWindowIteratorGetTags", as: SLSWindowIteratorGetTagsFn.self)

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> Unmanaged<CFArray>?

// NOTE: never drive the Space state itself (CGSManagedDisplaySetCurrentSpace,
// SLSShowSpaces/SLSHideSpaces) from here. Those flip WindowServer bookkeeping
// without the Mission Control choreography: the old Space keeps compositing
// underneath the new one, and once desynchronized even native transitions
// stop working until the WindowServer state resets.
enum Spaces {
    typealias DisplayInfo = (order: [UInt64], types: [UInt64: Int], current: UInt64)

    private static func managedDisplays() -> [[String: Any]] {
        CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
            .takeRetainedValue() as? [[String: Any]] ?? []
    }

    private static func parse(_ display: [String: Any]) -> DisplayInfo? {
        guard let spaces = display["Spaces"] as? [[String: Any]],
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

    // The managed-display dict of the display whose menu bar is active: the
    // display keyboard focus follows, and the only one the synthetic dock
    // swipes can act on. Falls back to the first listed display when no
    // identifier matches.
    private static func activeDisplay() -> [String: Any]? {
        let displays = managedDisplays()
        guard let active = SLSCopyActiveMenuBarDisplayIdentifier(CGSMainConnectionID())?.takeRetainedValue() as String?
        else { return displays.first }
        let target = canonicalUUID(active)
        return displays.first {
            ($0["Display Identifier"] as? String).map(canonicalUUID) == target
        } ?? displays.first
    }

    // Both the SLS call and the managed-display dicts can report the literal
    // "Main" instead of a UUID (and not necessarily in tandem), so both
    // sides are canonicalized to the UUID form before comparing.
    private static func canonicalUUID(_ identifier: String) -> String {
        guard identifier == "Main",
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue()
        else { return identifier }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // Space order, types, and current Space of the active display.
    static func activeDisplayInfo() -> DisplayInfo? {
        activeDisplay().flatMap(parse)
    }

    static func activeDisplayID() -> CGDirectDisplayID? {
        guard let identifier = activeDisplay()?["Display Identifier"] as? String else { return nil }
        if identifier == "Main" {
            return CGMainDisplayID()
        }
        guard let uuid = CFUUIDCreateFromString(nil, identifier as CFString) else { return nil }
        let id = CGDisplayGetDisplayIDFromUUID(uuid)
        return id == 0 ? nil : id
    }

    // Window IDs actually present in each Space that exists but is not
    // currently shown on any display. The per-Space window list is the
    // authority here: CGSCopySpacesForWindows keeps reporting a stale Space
    // assignment for the dead window an app caches after its last real
    // window closes, while the Space's own window list drops it immediately.
    static func windowsByNonVisibleSpace() -> [UInt64: Set<Int>] {
        var result: [UInt64: Set<Int>] = [:]
        for display in managedDisplays() {
            guard let info = parse(display) else { continue }
            for id in info.order where id != info.current {
                result[id] = windowIDs(inSpace: id)
            }
        }
        let real = realWindows(among: result.values.reduce(into: Set()) { $0.formUnion($1) })
        return result.mapValues { $0.intersection(real) }
    }

    // A fullscreen Space carries companions besides the user's window: the
    // slide-down toolbar (full display width at ~88pt, layer 0 - it passes
    // every CGWindowList realness heuristic and would otherwise produce a
    // phantom second switcher row), backdrop and shield windows. The WindowServer's
    // own records tell them apart: a window the user can hold carries tag
    // bit 0x1 (or the 0x2 + 0x80000000 combination) alongside attribute
    // bit 0x2 - the same predicate yabai filters with. One batched query
    // covers all candidates.
    static func realWindows(among windowIDs: Set<Int>) -> Set<Int> {
        guard !windowIDs.isEmpty,
              let query = SLSWindowQueryWindows(CGSMainConnectionID(),
                                                windowIDs.map { UInt32($0) } as CFArray,
                                                Int32(windowIDs.count))?.takeRetainedValue(),
              let iterator = SLSWindowQueryResultCopyWindows(query)?.takeRetainedValue() else {
            return windowIDs
        }
        var real: Set<Int> = []
        while SLSWindowIteratorAdvance(iterator) {
            let attributes = SLSWindowIteratorGetAttributes(iterator)
            let tags = SLSWindowIteratorGetTags(iterator)
            guard attributes & 0x2 != 0 || tags & 0x0400_0000_0000_0000 != 0 else { continue }
            guard tags & 0x1 != 0 || (tags & 0x2 != 0 && tags & 0x8000_0000 != 0) else { continue }
            real.insert(Int(SLSWindowIteratorGetWindowID(iterator)))
        }
        return real
    }

    // windowsByNonVisibleSpace() inverted for per-window lookups.
    static func nonVisibleSpaceByWindow() -> [Int: UInt64] {
        var byWindow: [Int: UInt64] = [:]
        for (space, windowIDs) in windowsByNonVisibleSpace() {
            for id in windowIDs { byWindow[id] = space }
        }
        return byWindow
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
        var psn = ProcessSerialNumber()
        let psnErr = GetProcessForPIDFallback(pid, &psn)
        guard psnErr == 0 else {
            Log.write("makeKey: GetProcessForPID(\(pid)) failed: \(psnErr)")
            return
        }
        let wid = UInt32(windowID)
        let frontErr = SLPSSetFrontProcessWithOptions(&psn, wid, 0x200)  // kCPSUserGenerated
        Log.write("makeKey: pid=\(pid) wid=\(wid) setFront=\(frontErr)")
        let point = CGPoint(x: -1, y: -1)
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        bytes.withUnsafeMutableBytes {
            $0.storeBytes(of: wid, toByteOffset: 0x3c, as: UInt32.self)
            $0.storeBytes(of: point, toByteOffset: 0x20, as: CGPoint.self)
        }
        bytes[0x08] = 0x01  // kCGEventLeftMouseDown
        _ = SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02  // kCGEventLeftMouseUp
        _ = SLPSPostEventRecordTo(&psn, &bytes)
    }

    static func windowIDs(inSpace spaceID: UInt64) -> Set<Int> {
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let list = SLSCopyWindowsWithOptionsAndTags(
            CGSMainConnectionID(), 0, [NSNumber(value: spaceID)] as CFArray, 0x2, &setTags, &clearTags
        )?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(list.map { $0.intValue })
    }

    // Marks every synthetic gesture event Cyclist posts, so the gesture
    // tap (DockSwipeRecognizer) can tell them from the user's real
    // trackpad swipes: real swipes are consumed and rerouted into chain
    // navigation, while these must reach the Dock untouched - swallowing
    // them would break SpaceNavigator, and re-triggering on them would
    // navigate in a loop.
    static let syntheticGestureTag: Int64 = 0x4359434C  // "CYCL"

    // Instant Space switch: synthetic trackpad dock-swipe gestures that
    // commit on a fling, so the Dock switches with no animation (~40ms
    // observed). One three-phase gesture per step; each gesture moves
    // exactly one Space, so distance comes from the count, not from the
    // magnitude of any one gesture.
    static func postDockSwipes(right: Bool, steps: Int) {
        for _ in 0..<max(1, steps) {
            postDockSwipeGesture(right: right)
        }
    }

    // In-place companion repaint for fullscreen Spaces (#63). After display
    // sleep the WindowServer purges the backing stores of windows on
    // non-visible Spaces; the instant snap never re-requests their contents,
    // so the fullscreen toolbar companion composites as nothing and the
    // backdrop shows through as a blank band. Ramping a dock swipe ~2pt and
    // closing with cancelled runs enough of the Dock's transition
    // choreography that the WindowServer re-requests window contents,
    // without committing a switch. Cancelled is the only closing phase that
    // stays put: the Dock latches the commit during the changed ramp, so
    // ending commits regardless of its own progress.
    //
    // Measured by --heal-experiment on macOS 27: a wedged band captures
    // flat black, and one ramp restores it to the same spread a band drawn
    // by a real fullscreen transition carries.
    //
    // Frames are scheduled rather than slept, to keep the main run loop
    // free, and the ramp is closed early when a navigation starts. Its
    // frames reach the Dock like any other gesture, and a swipe posted into
    // the middle of one is dropped.
    static func postFullscreenChromeHeal(right: Bool) {
        let width = CGDisplayBounds(activeDisplayID() ?? CGMainDisplayID()).width
        let peak = (right ? -1.0 : 1.0) * postedSwipeSign * 2.0 / width
        healGeneration += 1
        let generation = healGeneration
        healInFlight = true

        healFrame(phase: 1, progress: 0)  // began
        var delay: TimeInterval = 0
        for fraction in [0.25, 0.5, 0.75, 1.0, 0.6, 0.25] {
            delay += 0.016
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard healGeneration == generation else { return }
                healFrame(phase: 2, progress: peak * fraction)  // changed
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.016) {
            guard healGeneration == generation else { return }
            healInFlight = false
            healFrame(phase: 8, progress: 0)  // cancelled
        }
    }

    // Closes an in-flight heal at once. Returns whether one was open, so the
    // caller can pace its own post away from the closing frame.
    @discardableResult
    static func cancelChromeHeal() -> Bool {
        guard healInFlight else { return false }
        healGeneration += 1
        healInFlight = false
        healFrame(phase: 8, progress: 0)  // cancelled
        return true
    }

    private static var healGeneration = 0
    private static var healInFlight = false

    // One ramp frame. Carries no velocity, so nothing commits.
    private static func healFrame(phase: Int64, progress: Double) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(cgsEventTypeField, value: 30)      // DockControl
        event.setIntegerValueField(gestureHIDTypeField, value: 23)    // dock swipe
        event.setIntegerValueField(gesturePhaseField, value: phase)
        event.setIntegerValueField(swipeMotionField, value: 1)        // horizontal
        event.setDoubleValueField(swipePositionXField, value: 0.1)
        event.setDoubleValueField(swipeProgressField, value: progress)
        guard let augmentedEvent = augmented(event) else { return }
        postPair(augmentedEvent)
    }

    // The same ramp driven synchronously, for --heal-experiment: a CLI run
    // sleeps on the main thread, where scheduled frames would never fire.
    static func postHealRamp(right: Bool, peakPoints: Double) {
        let width = CGDisplayBounds(activeDisplayID() ?? CGMainDisplayID()).width
        let peak = (right ? -1.0 : 1.0) * postedSwipeSign * peakPoints / width
        healFrame(phase: 1, progress: 0)
        for fraction in [0.25, 0.5, 0.75, 1.0, 0.6, 0.25] {
            usleep(16000)
            healFrame(phase: 2, progress: peak * fraction)
        }
        usleep(16000)
        healFrame(phase: 8, progress: 0)
    }

    // The Dock reads a dock swipe from a serialized IOHID queue payload the
    // event carries in field 4205, not from the CGEvent fields the public
    // setters reach. An event describing the gesture only in those fields is
    // accepted by CGEventPost and then silently ignored. The payload is
    // written by round-tripping the event through CGEventCreateData /
    // CGEventCreateFromData and appending the field by hand. Every dock
    // event must also be followed by a companion gesture event (CGS type
    // 29); the pair is what the Dock acts on.
    //
    // Direction is inverted against the pre-27 encoding: rightward now
    // carries negative progress. The commit comes from the fling velocity on
    // the Ended phase, so progress stays near zero and nothing is left to
    // animate. Full-magnitude progress switches correctly but slides
    // visibly, which defeats the point.
    //
    // Layout and values follow mmathys/noswoosh and mgbowen/FasterSwiper.
    private static func postDockSwipeGesture(right: Bool) {
        // Build all three phases before posting any: a partial began/changed
        // sequence leaves the Dock mid-gesture on a blank Space.
        let phases: [Int64] = [1, 2, 4]  // began, changed, ended
        let events = phases.compactMap { phase -> CGEvent? in
            makeDockEvent(phase: phase, right: right).flatMap(augmented)
        }
        guard events.count == phases.count else { return }
        events.forEach(postPair)
    }

    // Reverses the posted direction when natural scrolling is off. The
    // reading side (DockSwipeRecognizer) needs no such correction: it maps
    // either reported sign onto the right chain step already.
    private static let postedSwipeSign: Double = {
        let natural = CFPreferencesCopyAppValue(
            "com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
        return natural ? 1 : -1
    }()

    private static func makeDockEvent(phase: Int64, right: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(cgsEventTypeField, value: 30)      // DockControl
        event.setIntegerValueField(gestureHIDTypeField, value: 23)    // dock swipe
        event.setIntegerValueField(gesturePhaseField, value: phase)
        event.setIntegerValueField(swipeMotionField, value: 1)        // horizontal
        event.setDoubleValueField(swipePositionXField, value: 0.1)
        // Neither FLT_TRUE_MIN (flushes to zero on Apple Silicon, losing the
        // sign) nor 0 (fixed1616 would serialize it as 0): only the sign of
        // this value picks the direction.
        event.setDoubleValueField(swipeProgressField,
                                  value: (right ? -1e-4 : 1e-4) * postedSwipeSign)
        if phase == 4 {
            event.setDoubleValueField(swipeVelocityXField,
                                      value: (right ? -9999.0 : 9999.0) * postedSwipeSign)
        }
        return event
    }

    // A dock event alone does nothing; the Dock acts on the pair.
    private static func postPair(_ dockEvent: CGEvent) {
        guard let companion = CGEvent(source: nil) else { return }
        companion.setIntegerValueField(.eventSourceUserData, value: syntheticGestureTag)
        companion.setIntegerValueField(cgsEventTypeField, value: 29)  // gesture envelope
        dockEvent.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
    }

    // Serialized CGEvents are a 4-byte version header followed by tagged
    // fields, so the payload is appended as one more field entry: a 16-bit
    // byte length, a 16-bit field id, then the bytes.
    private static func augmented(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data as Data? else { return nil }
        var bytes = [UInt8](data)
        guard bytes.starts(with: [0, 0, 0, 2]) else { return nil }
        let payload = gesturePayload(for: event)
        bytes.append(UInt8(payload.count >> 8))
        bytes.append(UInt8(payload.count & 0xFF))
        bytes.append(UInt8(rawIOHIDPayloadField >> 8))
        bytes.append(UInt8(rawIOHIDPayloadField & 0xFF))
        bytes.append(contentsOf: payload)
        guard let rebuilt = CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData) else { return nil }
        // The round trip drops eventSourceUserData, so the tag has to go on
        // again here. Without it DockSwipeRecognizer reads Cyclist's own
        // posted gesture as a user swipe and navigates straight back.
        rebuilt.setIntegerValueField(.eventSourceUserData, value: syntheticGestureTag)
        return rebuilt
    }

    // Values in the payload are 16.16 fixed point, so the smallest non-zero
    // magnitude is 1/65536. Anything finer truncates to zero and loses the
    // sign the direction depends on, so clamp it to one unit instead.
    private static func fixed1616(_ value: Double) -> Int32 {
        let scaled = Int32(truncatingIfNeeded: Int64(value * 65536.0))
        if scaled == 0 && value != 0 { return value > 0 ? 1 : -1 }
        return scaled
    }

    // IOHIDSystemQueueElement (28 bytes) + IOHIDFluidTouchGestureData (40
    // bytes), plus IOHIDVelocityEventData (28 bytes) when the gesture
    // carries velocity. Little-endian, unlike the big-endian CGEvent
    // wrapper. Dropping the velocity record on the Ended phase stops the
    // switch even when the velocities are zero.
    private static func gesturePayload(for event: CGEvent) -> [UInt8] {
        let phase = event.getIntegerValueField(gesturePhaseField)
        let velocityX = event.getDoubleValueField(swipeVelocityXField)
        let velocityY = event.getDoubleValueField(swipeVelocityYField)
        let withVelocity = velocityX != 0 || velocityY != 0 || phase == 4

        var bytes = [UInt8]()
        bytes.appendLE(event.timestamp != 0 ? event.timestamp : mach_absolute_time())
        bytes.appendLE(UInt64(0))                       // sender_id
        bytes.appendLE(UInt32(0))                       // options
        bytes.appendLE(UInt32(0))                       // attribute_length
        bytes.appendLE(UInt32(withVelocity ? 2 : 1))    // event_count

        bytes.appendLE(UInt32(40))                      // base.size
        bytes.appendLE(UInt32(23))                      // base.type, fluid touch gesture
        // The phase rides in the high byte of the options word.
        bytes.appendLE(UInt32(truncatingIfNeeded: phase & 0xFF) << 24)
        bytes.appendLE(UInt32(0))                       // base.depth + reserved
        bytes.appendLE(fixed1616(event.getDoubleValueField(swipePositionXField)))
        bytes.appendLE(fixed1616(event.getDoubleValueField(swipePositionYField)))
        bytes.appendLE(Int32(0))                        // position_z
        bytes.appendLE(UInt32(truncatingIfNeeded: event.getIntegerValueField(swipeMaskField)))
        bytes.appendLE(UInt16(truncatingIfNeeded: event.getIntegerValueField(swipeMotionField)))
        bytes.appendLE(UInt16(3))                       // gesture_flavor, Dock primary
        bytes.appendLE(fixed1616(event.getDoubleValueField(swipeProgressField)))

        if withVelocity {
            bytes.appendLE(UInt32(28))                  // base.size
            bytes.appendLE(UInt32(9))                   // base.type, velocity
            bytes.appendLE(UInt32(0))                   // base.options
            bytes.appendLE(UInt32(1))                   // base.depth = 1 + reserved
            bytes.appendLE(fixed1616(velocityX))
            bytes.appendLE(fixed1616(velocityY))
            bytes.appendLE(Int32(0))                    // velocity_z
        }
        return bytes
    }

}

// Undocumented CGEvent field indices. The gesture encoding is not in any
// header, so they are addressed by raw index.
private let cgsEventTypeField = CGEventField(rawValue: 55)!
private let gestureHIDTypeField = CGEventField(rawValue: 110)!
private let swipeMaskField = CGEventField(rawValue: 115)!
private let swipeMotionField = CGEventField(rawValue: 123)!
private let swipeProgressField = CGEventField(rawValue: 124)!
private let swipePositionXField = CGEventField(rawValue: 125)!
private let swipePositionYField = CGEventField(rawValue: 126)!
private let swipeVelocityXField = CGEventField(rawValue: 129)!
private let swipeVelocityYField = CGEventField(rawValue: 130)!
private let gesturePhaseField = CGEventField(rawValue: 132)!
private let rawIOHIDPayloadField = 4205

private extension Array where Element == UInt8 {
    mutating func appendLE(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: Int32) { appendLE(UInt32(bitPattern: value)) }
}
