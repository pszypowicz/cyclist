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
    // still functional at runtime, so they are resolved dynamically.
    private static let displayCapture = resolve("CGDisplayCreateImageForRect", DisplayCaptureFn.self)
    private static let windowCapture = resolve("CGWindowListCreateImage", WindowCaptureFn.self)
    private static let slsActiveSpace = resolve("SLSGetActiveSpace", ActiveSpaceFn.self)
    private static let mainConnection = resolve("CGSMainConnectionID", ConnectionFn.self)

    private static func resolve<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
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
        let ids = Spaces.windowIDs(inSpace: space)
        guard let window = CGWindows.real([.optionOnScreenOnly]).first(where: { ids.contains($0.id) }),
              window.bounds.width >= 64, window.bounds.height >= 64 else { return }
        let display = Spaces.activeDisplayID() ?? CGMainDisplayID()
        let displayBounds = CGDisplayBounds(display)
        let patch = CGRect(x: window.bounds.midX - 32 - displayBounds.minX,
                           y: window.bounds.midY - 32 - displayBounds.minY,
                           width: 64, height: 64)
        guard let screenImage = displayCapture?(display, patch)?.takeRetainedValue(),
              let screen = meanRGB(screenImage) else { return }
        // 8 = kCGWindowListOptionIncludingWindow
        guard let contentImage = windowCapture?(patch.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY),
                                                8, UInt32(window.id), 0)?.takeRetainedValue(),
              let content = meanRGB(contentImage) else { return }
        let distance = abs(screen.0 - content.0) + abs(screen.1 - content.1) + abs(screen.2 - content.2)
        guard distance > 60 else { return }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let slsActive = mainConnection.flatMap { connection in slsActiveSpace?(connection()) } ?? 0
        Log.error("WEDGE: space=\(space) wid=\(window.id) screenRGB=\(screen) windowRGB=\(content)"
            + " dist=\(distance) slsActive=\(slsActive)"
            + " front=\(front): arrived Space not composited (bookkeeping healthy, screen shows wallpaper)")
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
