import CoreGraphics
import Foundation

// Real user windows from CGWindowList. Layer 0 alone is not enough: apps
// keep invisible bookkeeping windows there (menu bar sized strips, cached
// Electron shells, the ~52pt fullscreen toolbar hover strip), so require
// visible alpha and a plausibly user-sized frame. Titles are populated only
// when Screen Recording permission is granted, and stay nil when empty.
struct CGWindowInfoLite {
    let id: Int
    let pid: pid_t
    let title: String?
    let bounds: CGRect  // global top-left-origin CG coordinates
}

enum CGWindows {
    // The realness predicate, shared by list snapshots and the focus
    // event-stream filter: layer 0, visible alpha, plausibly user-sized.
    // Returns the parsed bounds so list building decodes them only once.
    private static func realBounds(_ info: [String: Any]) -> CGRect? {
        guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width >= 100, bounds.height >= 80 else { return nil }
        return bounds
    }

    // Front-to-back for .optionOnScreenOnly, unspecified otherwise.
    static func real(_ options: CGWindowListOption) -> [CGWindowInfoLite] {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var result: [CGWindowInfoLite] = []
        for info in list {
            guard let bounds = realBounds(info),
                  let windowID = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let name = info[kCGWindowName as String] as? String
            result.append(CGWindowInfoLite(
                id: windowID,
                pid: pid,
                title: (name?.isEmpty == false) ? name : nil,
                bounds: bounds
            ))
        }
        return result
    }

    // Owner pid plus the realness verdict for one window in a single
    // round trip - what the focus/creation event stream filters with.
    // nil when the window is already gone.
    static func realOwner(of windowID: Int) -> (pid: pid_t, isReal: Bool)? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID))
                as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return (pid, realBounds(info) != nil)
    }
}
