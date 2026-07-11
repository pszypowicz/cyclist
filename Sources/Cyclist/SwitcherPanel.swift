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

    private let rowHeight: CGFloat = 28
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
    }

    // Advancing the selection means the user is browsing, so the panel shows
    // immediately even if the quick-tap grace delay has not elapsed yet.
    func select(index: Int) {
        model.selected = index
        show()
    }

    func show() {
        guard !panel.isVisible else { return }
        layout()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func layout() {
        let height = min(CGFloat(model.rows.count) * rowHeight + 16, maxHeight)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}
