import CoreGraphics
import Foundation

// The Screen Recording pane lists only apps that have attempted an
// actual capture through the legacy API: CGRequestScreenCaptureAccess
// shows the system dialog but creates no row, title reads via
// CGWindowList never register at all, and ScreenCaptureKit queries go
// through the picker-based consent flow that also leaves no row -
// which left Cyclist absent from the pane, with nothing for the user
// to enable. The throwaway 1pt legacy capture attempt after the
// request fails while ungranted, and failing is what registers the
// row.
enum ScreenRecordingPermission {
    private typealias WindowCaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    // Compile-time obsoleted in the macOS 26 SDK but still functional at
    // runtime, so resolved dynamically (same pattern as Diagnostics).
    private static let windowCapture = unsafeBitCast(
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!,
        to: WindowCaptureFn.self)

    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    static func request() {
        guard !granted else { return }
        CGRequestScreenCaptureAccess()
        // kCGWindowListOptionOnScreenOnly (1), kCGNullWindowID (0),
        // kCGWindowImageDefault (0).
        _ = windowCapture(CGRect(x: 0, y: 0, width: 1, height: 1), 1, 0, 0)?.takeRetainedValue()
    }
}
