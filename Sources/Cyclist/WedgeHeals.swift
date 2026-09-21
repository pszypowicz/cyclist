import AppKit

// Heal candidates for the purged fullscreen toolbar backing (#63), reached
// only from --heal-experiment. A recognized name returns true even when the
// operation is refused or skipped: only the before/after pixel capture in
// WedgeHealExperiment establishes whether the toolbar healed.
//
// Six candidates that synthesize no gesture were measured here and none of
// them healed anything: an SLS alpha nudge, a window-level nudge, an
// occlusion cover, a backing-resolution nudge, an Accessibility nudge on the
// owner's real window, and a mouse dwell at the top screen edge. They were
// removed rather than kept as a record, so nothing unreachable ships. The
// dock ramp is the only mechanism that has restored the band.
enum WedgeHeals {
    static let names: [String] = ["dock-ramp", "dock-ramp-wide"]

    static func describe(_ name: String) -> String {
        switch name {
        case "dock-ramp":
            return "Ramp a dock swipe ~2pt and cancel, without committing a switch."
        case "dock-ramp-wide":
            return "Ramp a dock swipe ~40pt and cancel, without committing a switch."
        default:
            return "Unknown heal."
        }
    }

    // The band is described by `companionWindowID`, `companionBounds` and
    // `ownerPID` so a candidate can target that window directly. The ramp
    // acts on the Space instead, and uses them only to confirm the band is
    // still on screen before anything is measured against it.
    @discardableResult
    static func apply(_ name: String,
                      companionWindowID: Int,
                      companionBounds: CGRect,
                      ownerPID: pid_t,
                      space: UInt64) -> Bool {
        guard names.contains(name) else { return false }
        guard let windowID = UInt32(exactly: companionWindowID), windowID != 0,
              ownerPID > 0, !companionBounds.isEmpty else {
            Log.write("wedge-heal: \(name) skipped: invalid target")
            return true
        }
        guard targetIsVisible(windowID, ownerPID: ownerPID, space: space) else {
            Log.write("wedge-heal: \(name) skipped: target is no longer visible on the active Space")
            return true
        }
        switch name {
        case "dock-ramp": Spaces.postHealRamp(right: false, peakPoints: 2)
        case "dock-ramp-wide": Spaces.postHealRamp(right: false, peakPoints: 40)
        default: return false
        }
        return true
    }

    private static func targetIsVisible(_ windowID: UInt32, ownerPID: pid_t, space: UInt64) -> Bool {
        guard Spaces.activeDisplayInfo()?.current == space,
              Spaces.windowIDs(inSpace: space).contains(Int(windowID)),
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(windowID) })
        else { return false }
        return (info[kCGWindowOwnerPID as String] as? Int) == Int(ownerPID)
            && (info[kCGWindowIsOnscreen as String] as? Bool) == true
    }
}
