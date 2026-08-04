#!/usr/bin/env swift
import AppKit

// Compares synthetic dock-swipe gesture shapes as SpaceNavigator candidates:
// the app's current two-phase pair, the same pair with a Changed phase
// inserted, and InstantSpaceSwitcher's three-phase encoding. Every post is
// single-shot - no retry - and arrival is verified by polling the
// WindowServer's Space bookkeeping, so round-trip runs measure exactly the
// drop rate the app's retry loop exists to cover. The probe also reports
// whether Mission Control or App Exposé is showing, using ISS's Dock
// window-list heuristic (layer-18/20 counts), so posting into an open
// Mission Control can be correlated with what the Dock did about it.

func usage() {
    print("""
    Compare synthetic dock-swipe gesture shapes (single-shot, no retry).

    Usage: swift scripts/gesture-shape-experiment.swift --variant <name> --direction <left|right> [flags]
           swift scripts/gesture-shape-experiment.swift --probe

    Variants:
      cyclist2  The app's current shape: Began + Ended, progress +-2.0 and
                velocity +-400 x steps on Ended only, gesture-envelope event
                after each dock event, direction also in the flag-bits field.
      cyclist3  cyclist2 with a Changed phase between Began and Ended,
                carrying the same progress/velocity as Ended.
      iss       InstantSpaceSwitcher's shape: Began + Changed + Ended, one
                dock event per phase (no envelope), no flag-bits direction,
                progress +-FLT_TRUE_MIN and velocity +-2000 x steps on every
                phase, velocity mirrored onto the Y field.

    Flags:
      --variant <name>      Gesture shape to post (required unless --probe)
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

let variantNames = ["cyclist2", "cyclist3", "iss"]
var variant: String?
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
    case "--variant":
        let name = value()
        guard variantNames.contains(name) else {
            fail("Unknown variant \"\(name)\"; one of: \(variantNames.joined(separator: ", "))")
        }
        variant = name
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
if !probeOnly {
    guard variant != nil else { usage(); fail("\n--variant is required") }
    guard direction != nil else { usage(); fail("\n--direction is required") }
}

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

let syntheticGestureTag: Int64 = 0x4359434C  // "CYCL", so a running Cyclist passes these through
let eventTypeField = CGEventField(rawValue: 55)!
let gestureHIDTypeField = CGEventField(rawValue: 110)!
let scrollYField = CGEventField(rawValue: 119)!
let swipeMotionField = CGEventField(rawValue: 123)!
let swipeProgressField = CGEventField(rawValue: 124)!
let swipeVelocityXField = CGEventField(rawValue: 129)!
let swipeVelocityYField = CGEventField(rawValue: 130)!
let gesturePhaseField = CGEventField(rawValue: 132)!
let flagBitsField = CGEventField(rawValue: 135)!
let zoomDeltaXField = CGEventField(rawValue: 139)!

// One dock event in the app's field encoding, plus the gesture-envelope
// event Spaces.postDockSwipePair sends after it.
func postCyclistPhase(_ phase: Int64, right: Bool, progress: Double, velocity: Double) {
    guard let dockEvent = CGEvent(source: nil), let gestureEvent = CGEvent(source: nil) else { return }
    dockEvent.setIntegerValueField(.eventSourceUserData, value: syntheticGestureTag)
    gestureEvent.setIntegerValueField(.eventSourceUserData, value: syntheticGestureTag)
    dockEvent.setIntegerValueField(eventTypeField, value: 30)      // DockControl
    dockEvent.setIntegerValueField(gestureHIDTypeField, value: 23) // dock swipe
    dockEvent.setIntegerValueField(gesturePhaseField, value: phase)
    dockEvent.setIntegerValueField(flagBitsField, value: right ? 1 : 0)
    dockEvent.setIntegerValueField(swipeMotionField, value: 1)     // horizontal
    dockEvent.setDoubleValueField(scrollYField, value: 0)
    // A zero zoom delta makes the Dock discard the event as a no-op.
    dockEvent.setDoubleValueField(zoomDeltaXField, value: Double(Float.leastNonzeroMagnitude))
    dockEvent.setDoubleValueField(swipeProgressField, value: progress)
    dockEvent.setDoubleValueField(swipeVelocityXField, value: velocity)
    dockEvent.setDoubleValueField(swipeVelocityYField, value: 0)
    gestureEvent.setIntegerValueField(eventTypeField, value: 29)   // gesture envelope
    dockEvent.post(tap: .cgSessionEventTap)
    gestureEvent.post(tap: .cgSessionEventTap)
}

// One dock event in ISS's field encoding: no envelope, no flag bits, no
// scroll/zoom fields, progress and velocity set on every phase, velocity
// mirrored onto Y (iss_post_dock_swipe in ISS.c).
func postISSPhase(_ phase: Int64, right: Bool, velocity: Double) {
    guard let dockEvent = CGEvent(source: nil) else { return }
    let sign = right ? 1.0 : -1.0
    dockEvent.setIntegerValueField(.eventSourceUserData, value: syntheticGestureTag)
    dockEvent.setIntegerValueField(eventTypeField, value: 30)
    dockEvent.setIntegerValueField(gestureHIDTypeField, value: 23)
    dockEvent.setIntegerValueField(gesturePhaseField, value: phase)
    dockEvent.setDoubleValueField(swipeProgressField, value: sign * Double(Float.leastNonzeroMagnitude))
    dockEvent.setIntegerValueField(swipeMotionField, value: 1)
    dockEvent.setDoubleValueField(swipeVelocityXField, value: sign * velocity)
    dockEvent.setDoubleValueField(swipeVelocityYField, value: sign * velocity)
    dockEvent.post(tap: .cgSessionEventTap)
}

func postGesture(variant: String, right: Bool, steps: Int) {
    let count = max(1, steps)
    switch variant {
    case "cyclist2", "cyclist3":
        let sign = right ? 1.0 : -1.0
        let progress = sign * 2.0
        let velocity = sign * 400.0 * Double(count)
        for _ in 0..<count {
            postCyclistPhase(1, right: right, progress: 0, velocity: 0)          // began
            if variant == "cyclist3" {
                postCyclistPhase(2, right: right, progress: progress, velocity: velocity)  // changed
            }
            postCyclistPhase(4, right: right, progress: progress, velocity: velocity)      // ended
        }
    case "iss":
        let velocity = 2000.0 * Double(count)
        for _ in 0..<count {
            postISSPhase(1, right: right, velocity: velocity)  // began
            postISSPhase(2, right: right, velocity: velocity)  // changed
            postISSPhase(4, right: right, velocity: velocity)  // ended
        }
    default:
        fail("unreachable")
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
func runLeg(_ index: Int, variant: String, right: Bool, steps: Int) -> Int? {
    guard let state = spaceState(),
          let currentIndex = state.order.firstIndex(of: state.current) else {
        fail("Cannot read Space state")
    }
    let targetIndex = currentIndex + (right ? steps : -steps)
    guard state.order.indices.contains(targetIndex) else {
        fail("Leg \(index): \(right ? "right" : "left") x\(steps) leaves the Space order \(state.order) from index \(currentIndex)")
    }
    let target = state.order[targetIndex]
    postGesture(variant: variant, right: right, steps: steps)
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
    let latency = runLeg(1, variant: variant!, right: firstRight, steps: steps)
    Thread.sleep(forTimeInterval: 0.5)
    printProbe("after:  ")
    print("RESULT: \(variant!) one-way \(latency != nil ? "LANDED" : "DROPPED")")
    exit(latency != nil ? 0 : 1)
}

var latencies: [Int] = []
var drops = 0
for leg in 1...(roundTrips * 2) {
    let preferRight = leg % 2 == 1 ? firstRight : !firstRight
    let right = viableDirection(preferRight: preferRight, steps: steps)
    if let latency = runLeg(leg, variant: variant!, right: right, steps: steps) {
        latencies.append(latency)
        usleep(UInt32(gapMs * 1000))
    } else {
        drops += 1
    }
}
printProbe("after:  ")
let total = roundTrips * 2
if latencies.isEmpty {
    print("RESULT: \(variant!) \(drops)/\(total) dropped, none landed")
    exit(1)
}
let sorted = latencies.sorted()
print("RESULT: \(variant!) landed \(latencies.count)/\(total), dropped \(drops),"
    + " latency ms min/med/max \(sorted.first!)/\(sorted[sorted.count / 2])/\(sorted.last!)")
