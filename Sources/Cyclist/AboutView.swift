import SwiftUI

private let repoURL = URL(string: "https://github.com/pszypowicz/cyclist")!
private let sponsorURL = URL(string: "https://github.com/sponsors/pszypowicz")!

struct AboutView: View {
    private let version: String = {
        let base = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "\(base) (beta)"
    }()

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text("Cyclist")
                .font(.title.bold())

            Text("Version \(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("by Przemysław Szypowicz")
                .font(.subheadline)

            Divider()

            Link(destination: repoURL) {
                Label("GitHub Repository", systemImage: "link")
            }

            Link(destination: sponsorURL) {
                HStack(spacing: 4) {
                    Text("Support this project")
                    Image(systemName: "heart.fill")
                }
            }
            .foregroundStyle(.pink)
        }
        .padding(24)
        .frame(width: 260)
    }

    static func showWindow() {
        let windowID = "about-cyclist"

        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == windowID }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: AboutView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        let fittingSize = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(windowID)
        window.title = "About Cyclist"
        window.contentView = hostingView
        window.center()
        // The window outlives its close button: the same instance is reordered
        // front on the next About click instead of being rebuilt.
        window.isReleasedWhenClosed = false
        // An accessory app has no Dock presence to click back to; floating
        // keeps the window reachable over whatever is frontmost.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
