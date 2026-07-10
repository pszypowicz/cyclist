import AppKit

// Private SkyLight/CoreGraphics symbols, the same ones AltTab and yabai rely
// on. Public APIs cannot report which Space a window belongs to, and Space
// membership is the only reliable way to separate a real window parked in
// another Space from the invisible bookkeeping windows many apps keep alive
// after their last real window closes.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: UInt32, _ mask: UInt32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> Unmanaged<CFArray>?

enum Spaces {
    private static let allSpacesMask: UInt32 = 7

    // The Space currently shown on each display.
    static func visibleSpaceIDs() -> Set<UInt64> {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?
            .takeRetainedValue() as? [[String: Any]] else { return [] }
        var ids: Set<UInt64> = []
        for display in displays {
            if let current = display["Current Space"] as? [String: Any],
               let id = current["id64"] as? UInt64 {
                ids.insert(id)
            }
        }
        return ids
    }

    // Empty for windows not assigned to any Space (closed-but-cached windows,
    // menu bar strips, and similar phantoms).
    static func spaceIDs(ofWindow windowID: Int) -> Set<UInt64> {
        guard let spaces = CGSCopySpacesForWindows(
            CGSMainConnectionID(), allSpacesMask, [NSNumber(value: windowID)] as CFArray
        )?.takeRetainedValue() as? [NSNumber] else { return [] }
        return Set(spaces.map { $0.uint64Value })
    }
}
