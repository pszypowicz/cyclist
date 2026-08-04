#!/usr/bin/env swift
import AppKit
import ApplicationServices
import ImageIO

// Collects a debug snapshot for the fullscreen toolbar-band wedge (#63):
// Space state, per-window WindowServer tags and z-order, per-window
// backing-store captures with a black/content verdict, an AX probe for the
// toolbar companion window, and the recent Cyclist unified log. Run it while
// the stale band is on screen; the delay exists so the capture can happen
// after switching back to the broken Space.

func usage() {
    print("""
    Collect a debug snapshot for the fullscreen toolbar-band wedge (issue #63).

    Run it when the stale band is visible. The script waits --delay seconds so
    you can switch to the broken fullscreen Space WITH CYCLIST (a native swipe
    or Mission Control would repaint the band and destroy the evidence). One
    beep marks the capture moment, a second beep marks completion.

    Usage: swift scripts/collect-wedge-debug.swift [flags]

    Flags:
      --output-dir <path>   Where to write the snapshot
                            (default: ~/Desktop/cyclist-wedge-debug-<timestamp>)
      --delay <seconds>     Wait before capturing (default: 5)
      --log-minutes <n>     Minutes of Cyclist unified log to include (default: 5)
      --no-captures         Skip pixel captures (no Screen Recording needed)
      -h, --help            Show this help.

    Pixel captures need Screen Recording granted to your terminal app, and the
    AX probe needs Accessibility. A missing grant skips that section and is
    noted in the report rather than failing the run.

    Example:
      swift scripts/collect-wedge-debug.swift --delay 8
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Flags

var outputDir: String?
var delay = 5
var logMinutes = 5
var captures = true

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else { fail("Missing value for \(flag)") }
        return arguments.removeFirst()
    }
    switch flag {
    case "--output-dir": outputDir = value()
    case "--delay":
        guard let parsed = Int(value()), parsed >= 0 else { fail("--delay wants a non-negative integer") }
        delay = parsed
    case "--log-minutes":
        guard let parsed = Int(value()), parsed > 0 else { fail("--log-minutes wants a positive integer") }
        logMinutes = parsed
    case "--no-captures": captures = false
    case "-h", "--help": usage(); exit(0)
    default: fail("Unknown flag: \(flag) (see --help)")
    }
}

// MARK: - Private WindowServer symbols (same set the app resolves)

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> Unmanaged<CFArray>?

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

func resolve<T>(_ name: String, as type: T.Type) -> T {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
        fail("Cannot resolve private symbol \(name); this macOS build is not compatible with this tool")
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

// The capture APIs are compile-time obsoleted in the macOS 26 SDK but still
// functional at runtime, so they are resolved dynamically like in the app.
typealias DisplayCaptureFn = @convention(c) (UInt32, CGRect) -> Unmanaged<CGImage>?
typealias WindowCaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
let displayCapture = resolve("CGDisplayCreateImageForRect", as: DisplayCaptureFn.self)
let windowCapture = resolve("CGWindowListCreateImage", as: WindowCaptureFn.self)

// MARK: - Space and window queries (mirrors Spaces.swift)

func windowIDs(inSpace spaceID: UInt64) -> [Int] {
    var setTags: UInt64 = 0
    var clearTags: UInt64 = 0
    guard let list = SLSCopyWindowsWithOptionsAndTags(
        CGSMainConnectionID(), 0, [NSNumber(value: spaceID)] as CFArray, 0x2, &setTags, &clearTags
    )?.takeRetainedValue() as? [NSNumber] else { return [] }
    return list.map { $0.intValue }
}

struct WindowRecord {
    let id: Int
    var tags: UInt64 = 0
    var attributes: UInt64 = 0
    // The predicate Spaces.realWindows filters with; false marks the
    // companion chrome (fullscreen toolbar, backdrop, shield).
    var isReal: Bool {
        (attributes & 0x2 != 0 || tags & 0x0400_0000_0000_0000 != 0)
            && (tags & 0x1 != 0 || (tags & 0x2 != 0 && tags & 0x8000_0000 != 0))
    }
}

func windowRecords(for ids: [Int]) -> [WindowRecord] {
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

// MARK: - Image helpers

func savePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// Strided mean keeps full-screen captures cheap under the interpreter.
func meanRGB(_ image: CGImage) -> (r: Int, g: Int, b: Int)? {
    guard let data = image.dataProvider?.data as Data? else { return nil }
    let bytesPerRow = image.bytesPerRow
    let bytesPerPixel = image.bitsPerPixel / 8
    guard bytesPerPixel >= 3 else { return nil }
    var r = 0, g = 0, b = 0, count = 0
    let step = max(1, min(image.width, image.height) / 128)
    var y = 0
    while y < image.height {
        var x = 0
        while x < image.width {
            let offset = y * bytesPerRow + x * bytesPerPixel
            b += Int(data[offset])
            g += Int(data[offset + 1])
            r += Int(data[offset + 2])
            count += 1
            x += step
        }
        y += step
    }
    guard count > 0 else { return nil }
    return (r / count, g / count, b / count)
}

// Matches the Diagnostics black threshold for the purged-backing verdict.
let blackLevel = 24
func verdict(_ rgb: (r: Int, g: Int, b: Int)?) -> String {
    guard let rgb else { return "NO-CAPTURE" }
    return max(rgb.r, max(rgb.g, rgb.b)) <= blackLevel ? "BLACK" : "CONTENT"
}

func describeRGB(_ rgb: (r: Int, g: Int, b: Int)?) -> String {
    guard let rgb else { return "-" }
    return "(\(rgb.r),\(rgb.g),\(rgb.b))"
}

func sanitize(_ name: String) -> String {
    String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" })
}

// MARK: - Output setup

let timestampFormatter = DateFormatter()
timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
let stamp = timestampFormatter.string(from: Date())
let outputURL = URL(fileURLWithPath: outputDir
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/cyclist-wedge-debug-\(stamp)").path)
do {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
} catch {
    fail("Cannot create output directory \(outputURL.path): \(error.localizedDescription)")
}

var report: [String] = []
func note(_ line: String) {
    print(line)
    report.append(line)
}

func writePlist(_ object: Any, name: String) {
    let url = outputURL.appendingPathComponent(name)
    guard let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    else {
        note("WARNING: could not serialize \(name)")
        return
    }
    try? data.write(to: url)
}

// MARK: - Delay so the broken Space can be brought back on screen

if delay > 0 {
    print("Switch to the broken fullscreen Space now - WITH CYCLIST, not a native")
    print("swipe or Mission Control (those repaint the band and destroy the evidence).")
    for remaining in stride(from: delay, through: 1, by: -1) {
        print("Capturing in \(remaining)s...")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
    }
}
NSSound.beep()
print("\u{07}Capturing.")

note("cyclist wedge debug snapshot - \(Date())")
note("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
note("frontmost app: \(NSWorkspace.shared.frontmostApplication.map { "\($0.localizedName ?? "?") pid=\($0.processIdentifier)" } ?? "?")")

let screenRecording = CGPreflightScreenCaptureAccess()
let axTrusted = AXIsProcessTrusted()
note("screen recording granted: \(screenRecording); accessibility granted: \(axTrusted)")
if captures && !screenRecording {
    note("WARNING: no Screen Recording for this terminal - pixel captures will be skipped")
}
if !axTrusted {
    note("WARNING: no Accessibility for this terminal - AX probe will be skipped")
}

// MARK: - Space state

guard let rawDisplays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
    .takeRetainedValue() as? [[String: Any]] else {
    fail("CGSCopyManagedDisplaySpaces returned nothing")
}
writePlist(rawDisplays, name: "managed-display-spaces.plist")

// Window metadata catalog: owner, bounds, layer, alpha for every known
// window, and front-to-back z-order for the on-screen ones.
let allInfo = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? []
let onScreenInfo = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
writePlist(onScreenInfo, name: "windows-onscreen.plist")

var metaByID: [Int: [String: Any]] = [:]
for info in allInfo {
    if let id = info[kCGWindowNumber as String] as? Int { metaByID[id] = info }
}
var zOrderByID: [Int: Int] = [:]
for (index, info) in onScreenInfo.enumerated() {
    if let id = info[kCGWindowNumber as String] as? Int { zOrderByID[id] = index }
}

struct SpaceWindowLine {
    let record: WindowRecord
    let pid: pid_t?
    let owner: String
    var axFound = false
    var capture: (r: Int, g: Int, b: Int)?
    var captured = false
}

var linesBySpace: [(display: String, space: UInt64, type: Int, windows: [SpaceWindowLine])] = []
var ownerPids: Set<pid_t> = []

for display in rawDisplays {
    let identifier = display["Display Identifier"] as? String ?? "?"
    guard let current = (display["Current Space"] as? [String: Any])?["id64"] as? UInt64 else { continue }
    let type = (display["Spaces"] as? [[String: Any]])?
        .first { ($0["id64"] as? UInt64) == current }?["type"] as? Int ?? -1
    note("")
    note("display \(identifier): current space=\(current) type=\(type)\(type == 4 ? " (fullscreen)" : "")")
    if type != 4 {
        note("  NOTE: not a fullscreen-type Space - if the band was on this display, the capture probably missed the broken Space")
    }
    var lines: [SpaceWindowLine] = []
    for record in windowRecords(for: windowIDs(inSpace: current)) {
        let meta = metaByID[record.id]
        let pid = (meta?[kCGWindowOwnerPID as String] as? Int).map(pid_t.init)
        if let pid { ownerPids.insert(pid) }
        lines.append(SpaceWindowLine(
            record: record,
            pid: pid,
            owner: meta?[kCGWindowOwnerName as String] as? String ?? "?"))
    }
    linesBySpace.append((identifier, current, type, lines))
}

// MARK: - AX probe: which space windows have an addressable AX element

AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
var axWindowIDs: Set<Int> = []
if axTrusted {
    note("")
    note("AX windows per owning app:")
    for pid in ownerPids.sorted() {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AnyObject] else {
            note("  pid=\(pid): AX window list unreadable")
            continue
        }
        for item in elements where CFGetTypeID(item) == AXUIElementGetTypeID() {
            let element = item as! AXUIElement
            var role: CFTypeRef?
            var subrole: CFTypeRef?
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            var wid: UInt32 = 0
            let widText = _AXUIElementGetWindow(element, &wid) == .success ? "\(wid)" : "?"
            if wid != 0 { axWindowIDs.insert(Int(wid)) }
            note("  pid=\(pid) wid=\(widText) role=\(role as? String ?? "?")"
                + " subrole=\(subrole as? String ?? "?") title=\"\(title as? String ?? "")\"")
        }
    }
}

// MARK: - Captures and the per-window report

for spaceIndex in linesBySpace.indices {
    let space = linesBySpace[spaceIndex]
    note("")
    note("space \(space.space) windows (z = front-to-back on-screen index):")
    for lineIndex in space.windows.indices {
        var line = space.windows[lineIndex]
        line.axFound = axWindowIDs.contains(line.record.id)
        if captures && screenRecording {
            // CGRect.null captures the window's own tight bounds; option 8 is
            // kCGWindowListOptionIncludingWindow, image option 1 ignores the
            // shadow framing. Black pixels here mean a purged backing store,
            // exactly like the Diagnostics wedge check.
            if let image = windowCapture(.null, 8, UInt32(line.record.id), 1)?.takeRetainedValue() {
                line.capture = meanRGB(image)
                line.captured = savePNG(image, to: outputURL.appendingPathComponent(
                    "window-\(line.record.id)-\(sanitize(line.owner)).png"))
            }
        }
        let meta = metaByID[line.record.id]
        let bounds = (meta?[kCGWindowBounds as String] as? [String: Any])
            .map { "\($0["X"] ?? "?"),\($0["Y"] ?? "?") \($0["Width"] ?? "?")x\($0["Height"] ?? "?")" } ?? "?"
        let layer = meta?[kCGWindowLayer as String] as? Int
        note("  wid=\(line.record.id) owner=\(line.owner) pid=\(line.pid.map(String.init) ?? "?")"
            + " layer=\(layer.map(String.init) ?? "?") bounds=\(bounds)"
            + " z=\(zOrderByID[line.record.id].map(String.init) ?? "offscreen")"
            + " tags=0x\(String(line.record.tags, radix: 16))"
            + " attrs=0x\(String(line.record.attributes, radix: 16))"
            + " real=\(line.record.isReal) ax=\(line.axFound)"
            + " backing=\(verdict(line.capture)) rgb=\(describeRGB(line.capture))")
        linesBySpace[spaceIndex].windows[lineIndex] = line
    }
    // Display captures: what is actually on screen, full frame plus the top
    // band where the toolbar companion lives.
    if captures && screenRecording {
        let displayID: CGDirectDisplayID
        if space.display == "Main" {
            displayID = CGMainDisplayID()
        } else if let uuid = CFUUIDCreateFromString(nil, space.display as CFString) {
            displayID = CGDisplayGetDisplayIDFromUUID(uuid)
        } else {
            displayID = 0
        }
        if displayID != 0 {
            let bounds = CGDisplayBounds(displayID)
            let local = CGRect(origin: .zero, size: bounds.size)
            if let full = displayCapture(displayID, local)?.takeRetainedValue() {
                _ = savePNG(full, to: outputURL.appendingPathComponent("display-\(displayID)-full.png"))
            }
            let band = CGRect(x: 0, y: 0, width: bounds.width, height: 120)
            if let top = displayCapture(displayID, band)?.takeRetainedValue() {
                let rgb = meanRGB(top)
                _ = savePNG(top, to: outputURL.appendingPathComponent("display-\(displayID)-top-band.png"))
                note("  display top band (120pt): \(verdict(rgb)) rgb=\(describeRGB(rgb))")
            }
        }
    }
}

// MARK: - Interpretation summary for the fullscreen displays

note("")
for space in linesBySpace where space.type == 4 {
    let companions = space.windows.filter { !$0.record.isReal }
    let blackCompanions = companions.filter { verdict($0.capture) == "BLACK" }
    if !blackCompanions.isEmpty {
        note("VERDICT space \(space.space): purged companion backing confirmed"
            + " (wid \(blackCompanions.map { String($0.record.id) }.joined(separator: ", ")))"
            + " - matches the #63 hypothesis")
    } else if captures && screenRecording {
        note("VERDICT space \(space.space): no black companion capture"
            + " - if the band still looks broken on screen, compare the display"
            + " captures against the window captures (ordering desync candidate)")
    }
    for companion in companions {
        note("  companion wid=\(companion.record.id) owner=\(companion.owner)"
            + " ax-element=\(companion.axFound ? "YES (AX heal path exists)" : "no")")
    }
}

// MARK: - Cyclist unified log

let logURL = outputURL.appendingPathComponent("cyclist-log.txt")
do {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = ["show", "--last", "\(logMinutes)m", "--info", "--debug",
                         "--predicate", "subsystem == \"cz.szypowi.cyclist\"", "--style", "syslog"]
    process.standardOutput = try FileHandle(forWritingTo: logURL)
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    note("")
    note("cyclist unified log (last \(logMinutes)m) -> cyclist-log.txt"
        + (process.terminationStatus == 0 ? "" : " (log show exited \(process.terminationStatus))"))
} catch {
    note("WARNING: could not collect unified log: \(error.localizedDescription)")
}

// MARK: - Wrap up

try? report.joined(separator: "\n").appending("\n")
    .write(to: outputURL.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
NSSound.beep()
print("\u{07}")
print("Done. Snapshot written to \(outputURL.path)")
print("Attach the whole directory to github.com/pszypowicz/cyclist/issues/63.")
