#!/usr/bin/env swift
import AppKit
import ApplicationServices

// Tests heal candidates for the fullscreen toolbar-band wedge (#63) against
// a live wedged Space. Captures every companion window's backing before and
// after the selected heal and prints which ones flipped from BLACK to
// CONTENT. Run it after the lock-screen repro, while the broken fullscreen
// Space is about to be on screen (use --delay to switch to it).

func usage() {
    print("""
    Test a heal candidate for the fullscreen toolbar-band wedge (issue #63).

    Reproduce first (lock the screen, unlock, switch to fullscreen Safari with
    Cyclist so the band is broken), then run this and switch back to the
    broken Space during the countdown. The script captures companion-window
    backings, applies the heal, captures again, and reports what flipped.
    If a heal reports NOT HEALED the Space is still wedged, so the next
    candidate can be tried without redoing the repro.

    Usage: swift scripts/wedge-heal-experiment.swift --heal <name> [flags]

    Heals:
      rubber-band  Partial dock swipe below the snap threshold; slides a few
                   pixels and springs back without switching Spaces.
      bounce       Committed normal-velocity swipe to a neighbor Space and
                   back, so the return arrival is an animated transition.
      hover        Synthetic mouse-move sweep across the toolbar band.
      menu-reveal  Synthetic mouse dwell at the top screen edge, then back.
      ax-sibling   1px AXPosition nudge on companion windows that expose AX
                   elements (the toolbar itself has none; this tests whether
                   AppKit repaints the sibling group together).
      none         No action; control run, before/after captures only.

    Flags:
      --heal <name>       Which heal to apply (required)
      --enter <left|right>  First post an instant Cyclist-style swipe in that
                          direction to enter the wedged Space (reproduces the
                          arrival), then run the heal. Without it, switch to
                          the wedged Space manually during the countdown.
      --delay <seconds>   Countdown before starting (default: 8)
      --settle <seconds>  Wait between heal and the after-capture (default: 2)
      --peak <progress>   rubber-band only: how far the partial slide goes,
                          in screen widths (default: 0.08). 0 posts just the
                          began/cancelled pair with no slide at all.
      --peak-pt <points>  rubber-band only: the peak expressed in screen
                          points (e.g. 1 for a 1pt slide); overrides --peak.
      -h, --help          Show this help.

    Needs Screen Recording (captures) granted to the terminal; ax-sibling
    also needs Accessibility.
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Flags

let healNames = ["rubber-band", "bounce", "hover", "menu-reveal", "ax-sibling", "none"]
var heal: String?
var enter: String?
var delay = 8
var settle = 2.0
var peak = 0.08
var peakPt: Double?

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("Missing value for \(flag)") }
        return arguments.removeFirst()
    }
    switch flag {
    case "--heal":
        let name = value()
        guard healNames.contains(name) else { fail("Unknown heal \"\(name)\"; one of: \(healNames.joined(separator: ", "))") }
        heal = name
    case "--enter":
        let direction = value()
        guard ["left", "right"].contains(direction) else { fail("--enter wants left or right") }
        enter = direction
    case "--delay":
        guard let parsed = Int(value()), parsed >= 0 else { fail("--delay wants a non-negative integer") }
        delay = parsed
    case "--settle":
        guard let parsed = Double(value()), parsed > 0 else { fail("--settle wants a positive number") }
        settle = parsed
    case "--peak":
        guard let parsed = Double(value()), parsed >= 0, parsed <= 0.5 else {
            fail("--peak wants a number between 0 and 0.5")
        }
        peak = parsed
    case "--peak-pt":
        guard let parsed = Double(value()), parsed >= 0, parsed <= 200 else {
            fail("--peak-pt wants a number between 0 and 200")
        }
        peakPt = parsed
    case "-h", "--help": usage(); exit(0)
    default: fail("Unknown flag: \(flag) (see --help)")
    }
}
guard let heal else { usage(); fail("\n--heal is required") }

// MARK: - Private WindowServer symbols

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> Unmanaged<CFArray>?

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

func resolve<T>(_ name: String, as type: T.Type) -> T {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
        fail("Cannot resolve private symbol \(name)")
    }
    return unsafeBitCast(symbol, to: type)
}

typealias SLSCopyWindowsWithOptionsAndTagsFn = @convention(c) (
    UInt32, UInt32, CFArray, UInt32,
    UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
) -> Unmanaged<CFArray>?
let SLSCopyWindowsWithOptionsAndTags =
    resolve("SLSCopyWindowsWithOptionsAndTags", as: SLSCopyWindowsWithOptionsAndTagsFn.self)

typealias SLSWindowQueryWindowsFn = @convention(c) (UInt32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
typealias SLSWindowQueryResultCopyWindowsFn = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
typealias SLSWindowIteratorAdvanceFn = @convention(c) (CFTypeRef) -> Bool
typealias SLSWindowIteratorGetWindowIDFn = @convention(c) (CFTypeRef) -> UInt32
typealias SLSWindowIteratorGetAttributesFn = @convention(c) (CFTypeRef) -> UInt64
typealias SLSWindowIteratorGetTagsFn = @convention(c) (CFTypeRef) -> UInt64
let SLSWindowQueryWindows = resolve("SLSWindowQueryWindows", as: SLSWindowQueryWindowsFn.self)
let SLSWindowQueryResultCopyWindows =
    resolve("SLSWindowQueryResultCopyWindows", as: SLSWindowQueryResultCopyWindowsFn.self)
let SLSWindowIteratorAdvance = resolve("SLSWindowIteratorAdvance", as: SLSWindowIteratorAdvanceFn.self)
let SLSWindowIteratorGetWindowID =
    resolve("SLSWindowIteratorGetWindowID", as: SLSWindowIteratorGetWindowIDFn.self)
let SLSWindowIteratorGetAttributes =
    resolve("SLSWindowIteratorGetAttributes", as: SLSWindowIteratorGetAttributesFn.self)
let SLSWindowIteratorGetTags = resolve("SLSWindowIteratorGetTags", as: SLSWindowIteratorGetTagsFn.self)

typealias WindowCaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let windowCapture = resolve("CGWindowListCreateImage", as: WindowCaptureFn.self)

// MARK: - Space and window state

struct WindowRecord {
    let id: Int
    var tags: UInt64 = 0
    var attributes: UInt64 = 0
    var isReal: Bool {
        (attributes & 0x2 != 0 || tags & 0x0400_0000_0000_0000 != 0)
            && (tags & 0x1 != 0 || (tags & 0x2 != 0 && tags & 0x8000_0000 != 0))
    }
}

func windowRecords(inSpace spaceID: UInt64) -> [WindowRecord] {
    var setTags: UInt64 = 0
    var clearTags: UInt64 = 0
    guard let list = SLSCopyWindowsWithOptionsAndTags(
        CGSMainConnectionID(), 0, [NSNumber(value: spaceID)] as CFArray, 0x2, &setTags, &clearTags
    )?.takeRetainedValue() as? [NSNumber] else { return [] }
    let ids = list.map { $0.intValue }
    var byID = [Int: WindowRecord](uniqueKeysWithValues: ids.map { ($0, WindowRecord(id: $0)) })
    if !ids.isEmpty,
       let query = SLSWindowQueryWindows(CGSMainConnectionID(),
                                         ids.map { UInt32($0) } as CFArray,
                                         Int32(ids.count))?.takeRetainedValue(),
       let iterator = SLSWindowQueryResultCopyWindows(query)?.takeRetainedValue() {
        while SLSWindowIteratorAdvance(iterator) {
            let id = Int(SLSWindowIteratorGetWindowID(iterator))
            byID[id]?.tags = SLSWindowIteratorGetTags(iterator)
            byID[id]?.attributes = SLSWindowIteratorGetAttributes(iterator)
        }
    }
    return ids.compactMap { byID[$0] }
}

// (order, current, type of current) for the display showing a fullscreen
// Space, falling back to the first display.
func activeSpaceState() -> (order: [UInt64], current: UInt64, type: Int)? {
    guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
        .takeRetainedValue() as? [[String: Any]] else { return nil }
    var fallback: (order: [UInt64], current: UInt64, type: Int)?
    for display in displays {
        guard let spaces = display["Spaces"] as? [[String: Any]],
              let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
        else { continue }
        let order = spaces.compactMap { $0["id64"] as? UInt64 }
        let type = spaces.first { ($0["id64"] as? UInt64) == current }?["type"] as? Int ?? -1
        let state = (order, current, type)
        if type == 4 { return state }
        if fallback == nil { fallback = state }
    }
    return fallback
}

// MARK: - Backing capture verdicts

let blackLevel = 24

func backingVerdict(_ windowID: Int) -> String {
    guard let image = windowCapture(.null, 8, UInt32(windowID), 1)?.takeRetainedValue(),
          let data = image.dataProvider?.data as Data? else { return "NO-CAPTURE" }
    let bytesPerRow = image.bytesPerRow
    let bytesPerPixel = image.bitsPerPixel / 8
    guard bytesPerPixel >= 3 else { return "NO-CAPTURE" }
    var peak = 0
    let step = max(1, min(image.width, image.height) / 128)
    var y = 0
    while y < image.height {
        var x = 0
        while x < image.width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            peak = max(peak, Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
            x += step
        }
        y += step
    }
    return peak <= blackLevel ? "BLACK" : "CONTENT"
}

func windowMeta(_ ids: [Int]) -> [Int: (owner: String, bounds: CGRect)] {
    var meta: [Int: (String, CGRect)] = [:]
    for info in (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? [] {
        guard let id = info[kCGWindowNumber as String] as? Int, ids.contains(id) else { continue }
        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
        var bounds = CGRect.zero
        if let dict = info[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: dict) ?? .zero
        }
        meta[id] = (owner, bounds)
    }
    return meta
}

// MARK: - Synthetic dock-swipe posting (same encoding as Spaces.swift)

// The Dock reads the gesture from a serialized IOHID queue payload in field
// 4205, so every event is round-tripped through its serialized form to carry
// one, and each dock event is followed by a companion gesture event. Keep
// this in step with Spaces.swift.
let syntheticGestureTag: Int64 = 0x4359434C  // "CYCL", so a running Cyclist passes these through
let rawIOHIDPayloadField = 4205
let cgsEventTypeField = CGEventField(rawValue: 55)!
let gestureHIDTypeField = CGEventField(rawValue: 110)!
let swipeMaskField = CGEventField(rawValue: 115)!
let swipeMotionField = CGEventField(rawValue: 123)!
let swipeProgressField = CGEventField(rawValue: 124)!
let swipePositionXField = CGEventField(rawValue: 125)!
let swipePositionYField = CGEventField(rawValue: 126)!
let swipeVelocityXField = CGEventField(rawValue: 129)!
let swipeVelocityYField = CGEventField(rawValue: 130)!
let gesturePhaseField = CGEventField(rawValue: 132)!

// Reverses the posted direction when natural scrolling is off.
let postedSwipeSign: Double = {
    let natural = CFPreferencesCopyAppValue(
        "com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
    return natural ? 1 : -1
}()

// Rightward carries negative progress, inverted against the pre-27 encoding.
func directionSign(right: Bool) -> Double { (right ? -1.0 : 1.0) * postedSwipeSign }

extension Array where Element == UInt8 {
    mutating func appendLE(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: Int32) { appendLE(UInt32(bitPattern: value)) }
}

// Payload values are 16.16 fixed point; anything finer than 1/65536 truncates
// to zero and loses the sign the direction depends on.
func fixed1616(_ value: Double) -> Int32 {
    let scaled = Int32(truncatingIfNeeded: Int64(value * 65536.0))
    if scaled == 0 && value != 0 { return value > 0 ? 1 : -1 }
    return scaled
}

func gesturePayload(for event: CGEvent) -> [UInt8] {
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

func augmented(_ event: CGEvent) -> CGEvent? {
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
    // The round trip drops eventSourceUserData.
    rebuilt.setIntegerValueField(.eventSourceUserData, value: syntheticGestureTag)
    return rebuilt
}

func postSwipeEvent(phase: Int64, progress: Double, velocity: Double) {
    guard let dockEvent = CGEvent(source: nil) else { return }
    dockEvent.setIntegerValueField(cgsEventTypeField, value: 30)   // DockControl
    dockEvent.setIntegerValueField(gestureHIDTypeField, value: 23) // dock swipe
    dockEvent.setIntegerValueField(gesturePhaseField, value: phase)
    dockEvent.setIntegerValueField(swipeMotionField, value: 1)     // horizontal
    dockEvent.setDoubleValueField(swipePositionXField, value: 0.1)
    dockEvent.setDoubleValueField(swipeProgressField, value: progress)
    if velocity != 0 { dockEvent.setDoubleValueField(swipeVelocityXField, value: velocity) }
    guard let augmentedEvent = augmented(dockEvent),
          let companion = CGEvent(source: nil) else { return }
    companion.setIntegerValueField(.eventSourceUserData, value: syntheticGestureTag)
    companion.setIntegerValueField(cgsEventTypeField, value: 29)   // gesture envelope
    augmentedEvent.post(tap: .cgSessionEventTap)
    companion.post(tap: .cgSessionEventTap)
}

// A gradual swipe that ramps up and back down, closed with the cancelled
// phase. The ended phase commits a switch regardless of its own progress -
// even ramp-up-then-ended-at-zero commits, so the Dock latches the commit
// during the changed ramp and only a cancel revokes it. The ramp exists to
// make the WindowServer render partial-slide frames.
func rubberBandSwipe(right: Bool, peak: Double) {
    let sign = directionSign(right: right)
    postSwipeEvent(phase: 1, progress: 0, velocity: 0)
    if peak > 0 {
        for fraction in [0.25, 0.5, 0.75, 1.0, 0.6, 0.25] {
            usleep(16000)
            postSwipeEvent(phase: 2, progress: sign * peak * fraction, velocity: 0)
        }
    }
    usleep(16000)
    postSwipeEvent(phase: 8, progress: 0, velocity: 0)  // cancelled
}

// The app's own instant snap: near-zero progress committed by a fling on the
// ended phase, no intermediate frames. This is the arrival that leaves purged
// backings unrendered.
func instantSwipe(right: Bool) {
    let sign = directionSign(right: right)
    postSwipeEvent(phase: 1, progress: sign * 1e-4, velocity: 0)
    postSwipeEvent(phase: 2, progress: sign * 1e-4, velocity: 0)
    postSwipeEvent(phase: 4, progress: sign * 1e-4, velocity: sign * 9999)
}

// A committed swipe at moderate progress and velocity, so the Dock runs a
// normal animated transition instead of the instant snap.
func animatedSwipe(right: Bool) {
    let sign = directionSign(right: right)
    postSwipeEvent(phase: 1, progress: 0, velocity: 0)
    for step in [0.1, 0.25, 0.4, 0.55] {
        usleep(16000)
        postSwipeEvent(phase: 2, progress: sign * step, velocity: 0)
    }
    usleep(16000)
    postSwipeEvent(phase: 4, progress: sign * 0.6, velocity: sign * 150)
}

// MARK: - Mouse-based heals

func postMouseMove(to point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cgSessionEventTap)
}

func mouseSweep(y: CGFloat, from startX: CGFloat, to endX: CGFloat, steps: Int) {
    let stepX = (endX - startX) / CGFloat(max(1, steps - 1))
    for index in 0..<steps {
        postMouseMove(to: CGPoint(x: startX + stepX * CGFloat(index), y: y))
        usleep(16000)
    }
}

// MARK: - Main

if delay > 0 {
    print("Reproduce first (lock, unlock, enter fullscreen Safari with Cyclist),")
    print("then switch back to the broken Space during this countdown.")
    for remaining in stride(from: delay, through: 1, by: -1) {
        print("Starting in \(remaining)s...")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
    }
}
NSSound.beep()

guard CGPreflightScreenCaptureAccess() else {
    fail("No Screen Recording for this terminal; the before/after verdicts need it")
}
if let enter {
    print("entering via instant swipe \(enter)")
    instantSwipe(right: enter == "right")
    Thread.sleep(forTimeInterval: 1.0)
}
guard let state = activeSpaceState() else { fail("Cannot read Space state") }
if state.type != 4 {
    print("WARNING: current Space \(state.current) is not fullscreen-type; results may be meaningless")
}
guard let currentIndex = state.order.firstIndex(of: state.current) else {
    fail("Current Space missing from its display's Space order")
}
// Swipe toward an existing neighbor, preferring the left one (a fullscreen
// Space usually sits at the right end of the order).
let towardRight = currentIndex == 0
let neighborExists = state.order.count > 1

let records = windowRecords(inSpace: state.current)
let meta = windowMeta(records.map(\.id))
let displayWidth = CGDisplayBounds(CGMainDisplayID()).width

func label(_ record: WindowRecord) -> String {
    let m = meta[record.id]
    let bounds = m?.bounds ?? .zero
    if !record.isReal, bounds.height >= 30, bounds.height <= 100, bounds.width >= displayWidth - 2,
       let owner = m?.owner, owner != "Dock", owner != "Window Server" {
        return "toolbar-band"
    }
    return record.isReal ? "content" : "companion"
}

func boundsText(_ id: Int) -> String {
    guard let bounds = meta[id]?.bounds else { return "?" }
    return "\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))x\(Int(bounds.height))"
}

print("space=\(state.current) heal=\(heal)")
var before: [Int: String] = [:]
for record in records {
    before[record.id] = backingVerdict(record.id)
    print("  before: wid=\(record.id) owner=\(meta[record.id]?.owner ?? "?")"
        + " kind=\(label(record)) bounds=\(boundsText(record.id)) backing=\(before[record.id]!)")
}

let originalMouse = CGEvent(source: nil)?.location ?? .zero

switch heal {
case "rubber-band":
    let effectivePeak = peakPt.map { $0 / displayWidth } ?? peak
    print("posting rubber-band swipe (toward \(towardRight ? "right" : "left"),"
        + " peak \(effectivePeak) = \(String(format: "%.1f", effectivePeak * displayWidth))pt)")
    rubberBandSwipe(right: towardRight, peak: effectivePeak)
case "bounce":
    guard neighborExists else { fail("No neighbor Space to bounce off") }
    print("animated swipe to neighbor and back")
    animatedSwipe(right: towardRight)
    Thread.sleep(forTimeInterval: 1.2)
    animatedSwipe(right: !towardRight)
    Thread.sleep(forTimeInterval: 1.2)
    if let landed = activeSpaceState(), landed.current != state.current {
        print("WARNING: did not land back on space \(state.current) (now \(landed.current)); verdicts below judge the wrong Space")
    }
case "hover":
    print("mouse sweep across the toolbar band")
    mouseSweep(y: 60, from: displayWidth * 0.2, to: displayWidth * 0.7, steps: 20)
    postMouseMove(to: originalMouse)
case "menu-reveal":
    print("mouse dwell at the top edge")
    mouseSweep(y: 4, from: originalMouse.x, to: displayWidth * 0.5, steps: 8)
    postMouseMove(to: CGPoint(x: displayWidth * 0.5, y: 0))
    Thread.sleep(forTimeInterval: 1.0)
    postMouseMove(to: originalMouse)
case "ax-sibling":
    guard AXIsProcessTrusted() else { fail("ax-sibling needs Accessibility for this terminal") }
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    let companionIDs = Set(records.filter { !$0.isReal }.map(\.id))
    let pids = Set(companionIDs.compactMap { id -> pid_t? in
        guard let owner = meta[id]?.owner else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == owner }?.processIdentifier
    })
    var nudged = 0
    for pid in pids {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AnyObject] else { continue }
        for item in elements where CFGetTypeID(item) == AXUIElementGetTypeID() {
            let element = item as! AXUIElement
            var wid: UInt32 = 0
            guard _AXUIElementGetWindow(element, &wid) == .success, companionIDs.contains(Int(wid))
            else { continue }
            var positionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
                  let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID() else {
                print("  ax-sibling: wid=\(wid) position unreadable")
                continue
            }
            var origin = CGPoint.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
            var moved = CGPoint(x: origin.x + 1, y: origin.y)
            let movedValue = AXValueCreate(.cgPoint, &moved)!
            let setResult = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, movedValue)
            usleep(50000)
            var back = origin
            let backValue = AXValueCreate(.cgPoint, &back)!
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, backValue)
            print("  ax-sibling: nudged wid=\(wid) set=\(setResult.rawValue)")
            nudged += 1
        }
    }
    print("  ax-sibling: nudged \(nudged) companion window(s)")
case "none":
    print("control run, no heal applied")
default:
    fail("unreachable")
}

Thread.sleep(forTimeInterval: settle)

if let landed = activeSpaceState(), landed.current != state.current {
    print("WARNING: no longer on space \(state.current) (now \(landed.current)); after-verdicts judge stale state")
}

var flipped: [Int] = []
var toolbarHealed = false
var toolbarSeen = false
for record in records {
    let after = backingVerdict(record.id)
    let was = before[record.id] ?? "?"
    let kind = label(record)
    if kind == "toolbar-band" {
        toolbarSeen = true
        toolbarHealed = after == "CONTENT"
    }
    if was == "BLACK" && after == "CONTENT" { flipped.append(record.id) }
    print("  after:  wid=\(record.id) owner=\(meta[record.id]?.owner ?? "?")"
        + " kind=\(kind) bounds=\(boundsText(record.id)) backing=\(was) -> \(after)")
}

NSSound.beep()
if toolbarSeen {
    print(toolbarHealed ? "RESULT: TOOLBAR HEALED" : "RESULT: NOT HEALED")
} else {
    print("RESULT: no toolbar-band window found on this Space (wrong Space?)")
}
if !flipped.isEmpty {
    print("flipped BLACK -> CONTENT: \(flipped.map(String.init).joined(separator: ", "))")
}
print("Visually confirm too: is the tab bar back on screen?")
