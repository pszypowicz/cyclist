import AppKit
import SwiftUI

struct SwitcherRow {
    let icon: NSImage?
    let title: String
    let subtitle: String?
    let annotation: String?
}

final class SwitcherViewModel: ObservableObject {
    @Published var rows: [SwitcherRow] = []
    @Published var selected: Int = 0
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                        HStack {
                            if let icon = row.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 18, height: 18)
                            }
                            (Text(row.title).fontWeight(.semibold)
                                + Text(row.subtitle.map { " - \($0)" } ?? ""))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 12)
                            if let annotation = row.annotation {
                                Text(annotation)
                                    .font(.system(size: 11))
                                    .foregroundColor(index == model.selected ? .white.opacity(0.8) : .secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(index == model.selected ? Color.accentColor : Color.clear)
                        .foregroundColor(index == model.selected ? .white : .primary)
                        .cornerRadius(6)
                        .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selected) { newValue in
                proxy.scrollTo(newValue)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
    }
}

// Non-activating borderless panel: it must never become the active app, or
// the MRU order (and "previous app" quick switching) would corrupt itself.
final class SwitcherPanel {
    private var panel: NSPanel
    private let model = SwitcherViewModel()
    private var lastOrderedFront = Date.distantPast

    // Must mirror the SwitcherView layout: row content plus its vertical
    // padding, the VStack spacing between rows, and the VStack padding.
    // Undercounting any of them makes the content overflow the window, so
    // the bottom inset visually vanishes as the list grows.
    private let rowHeight: CGFloat = 28
    private let rowSpacing: CGFloat = 2
    private let contentPadding: CGFloat = 8
    private let width: CGFloat = 520
    private let maxHeight: CGFloat = 560

    init() {
        panel = Self.makePanel(model: model)
        // After a display disconnect the long-lived panel stays ordered in
        // and correctly framed but the WindowServer stops compositing it
        // (onscreen=false) - the switcher silently vanishes. Rebuild the
        // window whenever the screen topology changes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.write("panel: screen parameters changed, rebuilding")
            // The notification also fires for resolution changes and display
            // sleep/wake; a switcher session may be live, so a visible panel
            // must survive the swap or the user keeps cycling blind.
            let wasVisible = self.panel.isVisible
            self.panel.orderOut(nil)
            self.panel = Self.makePanel(model: self.model)
            if wasVisible {
                self.show()
            }
        }
    }

    private static func makePanel(model: SwitcherViewModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        // Replaced panels are close()d so NSApp releases them; the default
        // release-when-closed would double-release under ARC.
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model))
        return panel
    }

    func setRows(_ rows: [SwitcherRow], selected: Int) {
        model.rows = rows
        model.selected = selected
        // Rows can shrink mid-session (quit/close from the list); a visible
        // panel resizes to fit instead of keeping dead space.
        if panel.isVisible {
            layout()
        }
    }

    // Advancing the selection means the user is browsing, so the panel shows
    // immediately even if the quick-tap grace delay has not elapsed yet.
    func select(index: Int) {
        model.selected = index
        show()
    }

    // The WindowServer can silently refuse to bring an existing panel
    // back: re-ordering a window front after an orderOut can stop
    // arriving on screen entirely while AppKit still reports it visible
    // (observed on macOS 26 after a fullscreen Space was destroyed; once
    // in that state it recurs on every re-show). A freshly created
    // window's first ordering reliably arrives, so every show that is
    // not already on screen starts from a fresh window - creation is a
    // few milliseconds, invisible next to the panel's own show delay.
    func show() {
        if panel.isVisible {
            if isOnScreen() { return }
            // Freshly ordered and still registering with the server (the
            // first render must commit before the window counts as on
            // screen); replacing it now would just reset that clock.
            if Date().timeIntervalSince(lastOrderedFront) < 1.0 { return }
            Log.write("panel: visible but not on screen, rebuilding")
        }
        let old = panel
        old.orderOut(nil)
        old.close()
        panel = Self.makePanel(model: model)
        layout()
        panel.orderFrontRegardless()
        lastOrderedFront = Date()
    }

    // The WindowServer's own record of the panel; AppKit's isVisible can
    // keep reporting true for a window the server no longer shows.
    private func isOnScreen() -> Bool {
        guard panel.windowNumber > 0,
              let info = CGWindowListCreateDescriptionFromArray(
                  [NSNumber(value: panel.windowNumber)] as CFArray) as? [[String: Any]],
              let record = info.first else { return false }
        return record[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func layout() {
        let rows = CGFloat(model.rows.count)
        let content = rows * rowHeight + max(0, rows - 1) * rowSpacing + contentPadding * 2
        let height = min(content, maxHeight)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}
