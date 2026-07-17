import AppKit

// Ground truth for Space transitions. Every bookkeeping signal
// (kCGWindowIsOnscreen, the onscreen window list, all current-space APIs)
// can report a perfectly healthy state on macOS 26 while the compositor
// shows bare wallpaper (the "wedge"): the arrived window's own backing
// store has been purged and nothing told the app to redraw, so the only
// trustworthy check is capturing the window's actual pixels.
//
// The wedge signature is that the window's own content capture is
// uniformly near-black (empty backing) even though a real window sits
// there - distinct from a merely dark window, which still has non-black
// chrome. Sampling both the window center and its top strip separates the
// two: a composited window has color somewhere, a purged one is black
// everywhere. The screen patch is captured only for logged context; the
// verdict does not depend on aligning the two captures (a persistent
// coordinate/color offset between the display and window capture made the
// old distance-only rule report false wedges on clean pages).
//
// This observes and logs only; the repaint fix itself is the arrival-time
// AX.repaintNudge in the navigators. The post-arrival check is gated on
// debug collection so it costs nothing in normal use - arm debug logging
// to see a per-arrival OK/WEDGE verdict.
enum Diagnostics {
    private typealias DisplayCaptureFn = @convention(c) (UInt32, CGRect) -> Unmanaged<CGImage>?
    private typealias WindowCaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    // The capture APIs are compile-time obsoleted in the macOS 26 SDK but
    // still functional at runtime, so they are resolved dynamically;
    // force-unwrapped like every other private symbol in the app.
    private static let displayCapture = resolve("CGDisplayCreateImageForRect", DisplayCaptureFn.self)
    private static let windowCapture = resolve("CGWindowListCreateImage", WindowCaptureFn.self)

    // A window content channel at or below this is treated as black; the
    // real wedge captures (0,0,0). Calibrated against live runs.
    private static let blackLevel = 24

    private static func resolve<T>(_ name: String, _ type: T.Type) -> T {
        unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)!, to: type)
    }

    // Schedules a compositing check shortly after a verified arrival, once
    // the arrival focus has settled. Debug-gated: no captures in normal use;
    // arm debug collection to see per-arrival verdicts (used to validate the
    // repaint nudge holds).
    static func verifyTransition(space: UInt64) {
        guard Log.debugEnabled, CGPreflightScreenCaptureAccess() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            check(space: space)
        }
    }

    private static func check(space: UInt64) {
        // The user may have navigated on; only judge the Space still shown.
        guard let info = Spaces.activeDisplayInfo(), info.current == space else { return }
        guard let verdict = compositeVerdict(space: space) else {
            Log.write("compositing: space=\(space) no judgeable window")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Log.write("compositing: \(verdict.composited ? "OK" : "WEDGE")"
            + " space=\(space) wid=\(verdict.windowID)"
            + " centerRGB=\(verdict.content) topRGB=\(verdict.top) screenRGB=\(verdict.screen)"
            + " dist=\(verdict.distance) front=\(front)")
    }

    struct CompositeVerdict {
        let composited: Bool
        let windowID: Int
        let screen: (Int, Int, Int)   // display patch at window center (context only)
        let content: (Int, Int, Int)  // window's own pixels at center
        let top: (Int, Int, Int)      // window's own pixels in its top strip
        let distance: Int             // |screen - content|, logged for context
    }

    // Pixel truth for the top real window on the Space. Wedged when the
    // window's own content is near-black at both the center and the top
    // strip (purged backing). nil = cannot judge (no capturable window, or
    // no Screen Recording grant).
    static func compositeVerdict(space: UInt64) -> CompositeVerdict? {
        let ids = Spaces.windowIDs(inSpace: space)
        guard let window = CGWindows.real([.optionOnScreenOnly]).first(where: { ids.contains($0.id) }),
              window.bounds.width >= 64, window.bounds.height >= 64 else { return nil }
        let display = Spaces.activeDisplayID() ?? CGMainDisplayID()
        let displayBounds = CGDisplayBounds(display)

        let centerPatch = CGRect(x: window.bounds.midX - 32 - displayBounds.minX,
                                 y: window.bounds.midY - 32 - displayBounds.minY,
                                 width: 64, height: 64)
        // Just inside the top edge, where window chrome lives; never black
        // on a composited window.
        let topPatch = CGRect(x: window.bounds.midX - 32 - displayBounds.minX,
                              y: window.bounds.minY + 8 - displayBounds.minY,
                              width: 64, height: 64)

        guard let content = windowMean(centerPatch, windowID: window.id, displayBounds: displayBounds),
              let top = windowMean(topPatch, windowID: window.id, displayBounds: displayBounds) else { return nil }
        let screenImage = displayCapture(display, centerPatch)?.takeRetainedValue()
        let screen = screenImage.flatMap(meanRGB) ?? (0, 0, 0)

        let wedged = maxChannel(content) < blackLevel && maxChannel(top) < blackLevel
        let distance = abs(screen.0 - content.0) + abs(screen.1 - content.1) + abs(screen.2 - content.2)
        return CompositeVerdict(composited: !wedged, windowID: window.id,
                                screen: screen, content: content, top: top, distance: distance)
    }

    static func isComposited(space: UInt64) -> Bool? {
        compositeVerdict(space: space)?.composited
    }

    // 8 = kCGWindowListOptionIncludingWindow; patch is display-local, the
    // window capture wants global coordinates.
    private static func windowMean(_ patch: CGRect, windowID: Int, displayBounds: CGRect) -> (Int, Int, Int)? {
        let image = windowCapture(patch.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY),
                                  8, UInt32(windowID), 0)?.takeRetainedValue()
        return image.flatMap(meanRGB)
    }

    private static func maxChannel(_ rgb: (Int, Int, Int)) -> Int {
        max(rgb.0, max(rgb.1, rgb.2))
    }

    private static func meanRGB(_ image: CGImage) -> (Int, Int, Int)? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        var r = 0, g = 0, b = 0, count = 0
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                b += Int(data[offset])
                g += Int(data[offset + 1])
                r += Int(data[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (r / count, g / count, b / count)
    }
}
