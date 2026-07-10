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

@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ cid: UInt32, _ display: CFString, _ space: UInt64)

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

    // Make a specific window key through the WindowServer, the same way
    // AltTab and yabai focus windows. Activating the app alone after a Space
    // change leaves the WindowServer half-switched: the previous fullscreen
    // Space keeps compositing underneath and the menu bar still names the
    // old app. The 0xf8-byte records are synthesized window-server focus
    // events; 0x01/0x02 are their activate/deactivate variants.
    static func makeKey(pid: pid_t, windowID: Int) {
        guard let setFront = SLPSSetFrontProcessWithOptions,
              let postEvent = SLPSPostEventRecordTo,
              let getPSN = GetProcessForPIDFallback else { return }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == 0 else { return }
        let wid = UInt32(windowID)
        _ = setFront(&psn, wid, 0x200)  // kCPSUserGenerated
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: wid) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEvent(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEvent(&psn, &bytes)
    }

    private static func windowIDs(inSpace spaceID: UInt64) -> Set<Int> {
        guard let copyWindows = SLSCopyWindowsWithOptionsAndTags else { return [] }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let list = copyWindows(
            CGSMainConnectionID(), 0, [NSNumber(value: spaceID)] as CFArray, 0x2, &setTags, &clearTags
        )?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(list.map { $0.intValue })
    }

    // Make the given Space current on whichever display owns it. Activating
    // an app never switches Spaces by itself; the Dock performs this step for
    // the native switcher, so Cyclist has to as well. The jump is instant,
    // without the sliding animation.
    static func switchTo(spaceID: UInt64) {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
            .takeRetainedValue() as? [[String: Any]] else { return }
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            if spaces.contains(where: { ($0["id64"] as? UInt64) == spaceID }) {
                CGSManagedDisplaySetCurrentSpace(CGSMainConnectionID(), identifier as CFString, spaceID)
                return
            }
        }
    }

}
