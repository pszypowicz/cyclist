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

private let SLSCopyWindowsWithOptionsAndTags: SLSCopyWindowsWithOptionsAndTagsFn? = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "SLSCopyWindowsWithOptionsAndTags") else { return nil }
    return unsafeBitCast(symbol, to: SLSCopyWindowsWithOptionsAndTagsFn.self)
}()

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
