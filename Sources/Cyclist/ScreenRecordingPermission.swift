import CoreGraphics

// Screen Recording on macOS 26, as established empirically: the
// Screen & System Audio Recording pane is an allowlist editor that
// shows only granted apps - the + button there IS the grant. Nothing
// an app does creates a row: CGRequestScreenCaptureAccess shows the
// system dialog (at most once per TCC state) but writes nothing,
// title reads via CGWindowList never touch TCC, and neither a failing
// SCShareableContent query nor a legacy CGWindowListCreateImage
// attempt registers anything (both tried against a fresh tccd, with
// the dialog answered). So: request once for the system's own
// explanation dialog, and otherwise point the user at the pane.
enum ScreenRecordingPermission {
    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    static func request() {
        guard !granted else { return }
        CGRequestScreenCaptureAccess()
    }
}
