#!/usr/bin/env swift
import AppKit

// Measures the synthetic dock-swipe gesture the app posts (Spaces.swift):
// how often the Dock acts on it and how long each switch takes to land.
// Every post is single-shot - no retry - and arrival is verified by polling
// the WindowServer's Space bookkeeping, so round-trip runs measure exactly
// the drop rate SpaceNavigator's "gave up" line reports. The probe also
// reports whether Mission Control or App Exposé is showing, using ISS's Dock
// window-list heuristic (layer-18/20 counts), so posting into an open
// Mission Control can be correlated with what the Dock did about it.
//
// Re-run this after a macOS update: the gesture encoding is undocumented and
// has broken across major versions before.

func usage() {
    print("""
    Measure the synthetic dock-swipe gesture (single-shot, no retry).

    Usage: swift scripts/gesture-shape-experiment.swift --direction <left|right> [flags]
           swift scripts/gesture-shape-experiment.swift --probe

    Flags:
      --direction <l|r>     Swipe direction of the first leg (required unless --probe)
      --steps <n>           Spaces to cross per leg (default: 1)
      --round-trips <n>     Legs there and back, alternating direction; 0
                            posts a single one-way gesture (default: 0)
      --gap-ms <n>          Settle after a landed leg before the next post,
                            mimicking the app's postSettleGap (default: 100)
      --timeout-ms <n>      How long a leg polls for arrival before counting
                            the gesture as dropped (default: 1500)
      --delay <seconds>     Countdown before the first post (default: 0)
      --probe               Print Space state and Mission Control verdict, exit
      -h, --help            Show this help.

    All events carry Cyclist's synthetic-gesture tag, so a running Cyclist
    passes them through to the Dock exactly like the app's own posts.
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Flags

var direction: String?
var steps = 1
var roundTrips = 0
var gapMs = 100
var timeoutMs = 1500
var delay = 0
var probeOnly = false

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("Missing value for \(flag)") }
        return arguments.removeFirst()
    }
    switch flag {
    case "--direction":
        let name = value()
        guard ["left", "right"].contains(name) else { fail("--direction wants left or right") }
        direction = name
    case "--steps":
        guard let parsed = Int(value()), parsed >= 1 else { fail("--steps wants a positive integer") }
        steps = parsed
    case "--round-trips":
        guard let parsed = Int(value()), parsed >= 0 else { fail("--round-trips wants a non-negative integer") }
        roundTrips = parsed
    case "--gap-ms":
        guard let parsed = Int(value()), parsed >= 0 else { fail("--gap-ms wants a non-negative integer") }
        gapMs = parsed
    case "--timeout-ms":
        guard let parsed = Int(value()), parsed >= 100 else { fail("--timeout-ms wants an integer >= 100") }
        timeoutMs = parsed
    case "--delay":
        guard let parsed = Int(value()), parsed >= 0 else { fail("--delay wants a non-negative integer") }
        delay = parsed
    case "--probe": probeOnly = true
    case "-h", "--help": usage(); exit(0)
    default: fail("Unknown flag: \(flag) (see --help)")
    }
}
if !probeOnly, direction == nil { usage(); fail("\n--direction is required") }

// MARK: - Space state

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> Unmanaged<CFArray>?

// Order and current Space of the display whose menu bar is active is what
// the app navigates; a single-display machine makes the first entry fine.
func spaceState() -> (order: [UInt64], current: UInt64)? {
    guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
        .takeRetainedValue() as? [[String: Any]] else { return nil }
    for display in displays {
        guard let spaces = display["Spaces"] as? [[String: Any]],
              let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64
        else { continue }
        return (spaces.compactMap { $0["id64"] as? UInt64 }, current)
    }
    return nil
}

// ISS's overlay heuristic: Dock-owned on-screen windows at layer 18 mark an
// overlay session; more layer-20 windows than layer-18 means Mission
// Control, fewer-or-equal means App Exposé.
func overlayVerdict() -> String {
    guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
        as? [[String: Any]] else { return "unknown" }
    var layer18 = 0
    var layer20 = 0
    for window in list where window[kCGWindowOwnerName as String] as? String == "Dock" {
        switch window[kCGWindowLayer as String] as? Int {
        case 18: layer18 += 1
        case 20: layer20 += 1
        default: break
        }
    }
    guard layer18 > 0, layer20 > 0 else { return "inactive" }
    return layer20 > layer18 ? "mission-control" : "app-expose"
}

func printProbe(_ prefix: String) {
    guard let state = spaceState() else { fail("Cannot read Space state") }
    print("\(prefix)spaces=\(state.order) current=\(state.current) overlay=\(overlayVerdict())")
}

// MARK: - Gesture posting

// Mirrors Spaces.postDockSwipeGesture. The Dock reads the gesture from a
// serialized IOHID queue payload in field 4205, not from the CGEvent fields
// the public setters reach, so the event is round-tripped through its
// serialized form to carry it. Each dock event needs a companion gesture
// event, and the commit comes from the fling velocity on the Ended phase.
let syntheticGestureTag: Int64 = 0x4359434C  // "CYCL", so a running Cyclist passes these through
let rawIOHIDPayloadField = 4205

func field(_ raw: UInt32) -> CGEventField { CGEventField(rawValue: raw)! }
let cgsEventTypeField = field(55)
let gestureHIDTypeField = field(110)
let swipeMaskField = field(115)
let swipeMotionField = field(123)
let swipeProgressField = field(124)
let swipePositionXField = field(125)
let swipePositionYField = field(126)
let swipeVelocityXField = field(129)
let swipeVelocityYField = field(130)
let gesturePhaseField = field(132)

// Reverses the posted direction when natural scrolling is off.
let postedSwipeSign: Double = {
    let natural = CFPreferencesCopyAppValue(
        "com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool ?? true
    return natural ? 1 : -1
}()

extension Array where Element == UInt8 {
    mutating func appendLE(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ value: Int32) { appendLE(UInt32(bitPattern: value)) }
}

// Values in the payload are 16.16 fixed point; anything finer than 1/65536
// truncates to zero and loses the sign the direction depends on.
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

func makeDockEvent(phase: Int64, right: Bool) -> CGEvent? {
    guard let event = CGEvent(source: nil) else { return nil }
    event.setIntegerValueField(cgsEventTypeField, value: 30)      // DockControl
    event.setIntegerValueField(gestureHIDTypeField, value: 23)    // dock swipe
    event.setIntegerValueField(gesturePhaseField, value: phase)
    event.setIntegerValueField(swipeMotionField, value: 1)        // horizontal
    event.setDoubleValueField(swipePositionXField, value: 0.1)
    event.setDoubleValueField(swipeProgressField,
                              value: (right ? -1e-4 : 1e-4) * postedSwipeSign)
    if phase == 4 {
        event.setDoubleValueField(swipeVelocityXField,
                                  value: (right ? -9999.0 : 9999.0) * postedSwipeSign)
    }
    return event
}

func postPair(_ dockEvent: CGEvent) {
    guard let companion = CGEvent(source: nil) else { return }
    companion.setIntegerValueField(.eventSourceUserData, value: syntheticGestureTag)
    companion.setIntegerValueField(cgsEventTypeField, value: 29)  // gesture envelope
    dockEvent.post(tap: .cgSessionEventTap)
    companion.post(tap: .cgSessionEventTap)
}

func postGesture(right: Bool, steps: Int) {
    for _ in 0..<max(1, steps) {
        let events = [Int64(1), 2, 4].compactMap { makeDockEvent(phase: $0, right: right).flatMap(augmented) }
        guard events.count == 3 else { return }
        events.forEach(postPair)
    }
}

// MARK: - Legs and verification

// Polls the Space bookkeeping until the expected Space is current. Returns
// the latency in ms, or nil when the timeout expires (gesture dropped).
func pollArrival(target: UInt64, timeoutMs: Int) -> Int? {
    let start = Date()
    while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
        if spaceState()?.current == target {
            return Int(Date().timeIntervalSince(start) * 1000)
        }
        usleep(20000)
    }
    return nil
}

// The direction a round-trip leg actually takes: the preferred alternating
// one when it stays inside the Space order, otherwise the other - a dropped
// leg leaves the position unchanged, and blindly alternating from there
// would step off the edge.
func viableDirection(preferRight: Bool, steps: Int) -> Bool {
    guard let state = spaceState(),
          let currentIndex = state.order.firstIndex(of: state.current) else {
        fail("Cannot read Space state")
    }
    let canRight = state.order.indices.contains(currentIndex + steps)
    let canLeft = state.order.indices.contains(currentIndex - steps)
    if preferRight, canRight { return true }
    if !preferRight, canLeft { return false }
    guard canRight || canLeft else {
        fail("Neither direction can move \(steps) step(s) within \(state.order)")
    }
    return canRight
}

// One posted gesture with verified arrival. Returns the latency, nil for a
// drop; fails hard when the requested distance leaves the Space order.
func runLeg(_ index: Int, right: Bool, steps: Int) -> Int? {
    guard let state = spaceState(),
          let currentIndex = state.order.firstIndex(of: state.current) else {
        fail("Cannot read Space state")
    }
    let targetIndex = currentIndex + (right ? steps : -steps)
    guard state.order.indices.contains(targetIndex) else {
        fail("Leg \(index): \(right ? "right" : "left") x\(steps) leaves the Space order \(state.order) from index \(currentIndex)")
    }
    let target = state.order[targetIndex]
    postGesture(right: right, steps: steps)
    let latency = pollArrival(target: target, timeoutMs: timeoutMs)
    let verdict = latency.map { "LANDED \($0)ms" } ?? "DROPPED (still \(spaceState()?.current ?? 0))"
    print("leg \(index) \(right ? "right" : "left"): \(state.current) -> \(target) \(verdict)")
    return latency
}

// MARK: - Main

if probeOnly {
    printProbe("")
    exit(0)
}

for remaining in stride(from: delay, through: 1, by: -1) {
    print("Starting in \(remaining)s...")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 1)
}

let firstRight = direction == "right"
printProbe("before: ")

if roundTrips == 0 {
    let latency = runLeg(1, right: firstRight, steps: steps)
    Thread.sleep(forTimeInterval: 0.5)
    printProbe("after:  ")
    print("RESULT: one-way \(latency != nil ? "LANDED" : "DROPPED")")
    exit(latency != nil ? 0 : 1)
}

var latencies: [Int] = []
var drops = 0
for leg in 1...(roundTrips * 2) {
    let preferRight = leg % 2 == 1 ? firstRight : !firstRight
    let right = viableDirection(preferRight: preferRight, steps: steps)
    if let latency = runLeg(leg, right: right, steps: steps) {
        latencies.append(latency)
        usleep(UInt32(gapMs * 1000))
    } else {
        drops += 1
    }
}
printProbe("after:  ")
let total = roundTrips * 2
if latencies.isEmpty {
    print("RESULT: \(drops)/\(total) dropped, none landed")
    exit(1)
}
let sorted = latencies.sorted()
print("RESULT: landed \(latencies.count)/\(total), dropped \(drops),"
    + " latency ms min/med/max \(sorted.first!)/\(sorted[sorted.count / 2])/\(sorted.last!)")
