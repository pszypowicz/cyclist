import SwiftUI

// Shared presenter for the app's small utility windows (About, Settings).
enum UtilityWindow {
    static func show(id: String, title: String, content: some View) {
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == id }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let fittingSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.title = title
        window.contentView = hostingView
        window.center()
        // The window outlives its close button: the same instance is
        // reordered front on the next menu click instead of being rebuilt.
        window.isReleasedWhenClosed = false
        // An accessory app has no Dock presence to click back to; floating
        // keeps the window reachable over whatever is frontmost.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
