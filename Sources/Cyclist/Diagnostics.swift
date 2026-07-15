import AppKit

// Debug-only ground truth for Space transitions. Every bookkeeping signal
// (kCGWindowIsOnscreen, the onscreen window list, all current-space APIs)
// can report a perfectly healthy state on macOS 26 while the compositor
// shows bare wallpaper, so the only trustworthy check is comparing actual
// screen pixels against the window's own content. Runs only while debug
// log collection is armed and Screen Recording is granted; logs a WEDGE
// line at error level on mismatch and never attempts a repair.
enum Diagnostics {
    private typealias DisplayCaptureFn = @convention(c) (UInt32, CGRect) -> Unmanaged<CGImage>?
    private typealias WindowCaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private typealias ActiveSpaceFn = @convention(c) (UInt32) -> UInt64
    private typealias ConnectionFn = @convention(c) () -> UInt32

    // The capture APIs are compile-time obsoleted in the macOS 26 SDK but
    // still functional at runtime, so they are resolved dynamically;
    // force-unwrapped like every other private symbol in the app.
    private static let displayCapture = resolve("CGDisplayCreateImageForRect", DisplayCaptureFn.self)
    private static let windowCapture = resolve("CGWindowListCreateImage", WindowCaptureFn.self)
    private static let slsActiveSpace = resolve("SLSGetActiveSpace", ActiveSpaceFn.self)
    private static let mainConnection = resolve("CGSMainConnectionID", ConnectionFn.self)

    private static func resolve<T>(_ name: String, _ type: T.Type) -> T {
        unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)!, to: type)
    }

    // Schedules a composite check shortly after a verified arrival, once
    // the arrival focus has settled.
    static func verifyTransition(space: UInt64) {
        guard Log.debugEnabled, CGPreflightScreenCaptureAccess() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            check(space: space)
        }
    }

    private static func check(space: UInt64) {
        // The user may have navigated on; only judge the Space still shown.
        guard let info = Spaces.activeDisplayInfo(), info.current == space else { return }
        guard let verdict = compositeVerdict(space: space), !verdict.composited else { return }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let slsActive = slsActiveSpace(mainConnection())
        Log.error("WEDGE: space=\(space) wid=\(verdict.windowID) screenRGB=\(verdict.screen)"
            + " windowRGB=\(verdict.content) dist=\(verdict.distance) slsActive=\(slsActive)"
            + " front=\(front): arrived Space not composited (bookkeeping healthy, screen shows wallpaper)")
    }

    struct CompositeVerdict {
        let composited: Bool
        let windowID: Int
        let screen: (Int, Int, Int)
        let content: (Int, Int, Int)
        let distance: Int
    }

    // Pixel truth for the Space on screen: compares a patch of the display
    // against the top window's own content. nil = cannot judge (no
    // capturable window in the Space, or no Screen Recording grant).
    static func compositeVerdict(space: UInt64) -> CompositeVerdict? {
        let ids = Spaces.windowIDs(inSpace: space)
        guard let window = CGWindows.real([.optionOnScreenOnly]).first(where: { ids.contains($0.id) }),
              window.bounds.width >= 64, window.bounds.height >= 64 else { return nil }
        let display = Spaces.activeDisplayID() ?? CGMainDisplayID()
        let displayBounds = CGDisplayBounds(display)
        let patch = CGRect(x: window.bounds.midX - 32 - displayBounds.minX,
                           y: window.bounds.midY - 32 - displayBounds.minY,
                           width: 64, height: 64)
        guard let screenImage = displayCapture(display, patch)?.takeRetainedValue(),
              let screen = meanRGB(screenImage) else { return nil }
        // 8 = kCGWindowListOptionIncludingWindow
        guard let contentImage = windowCapture(patch.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY),
                                               8, UInt32(window.id), 0)?.takeRetainedValue(),
              let content = meanRGB(contentImage) else { return nil }
        let distance = abs(screen.0 - content.0) + abs(screen.1 - content.1) + abs(screen.2 - content.2)
        return CompositeVerdict(composited: distance <= 60, windowID: window.id,
                                screen: screen, content: content, distance: distance)
    }

    static func isComposited(space: UInt64) -> Bool? {
        compositeVerdict(space: space)?.composited
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
