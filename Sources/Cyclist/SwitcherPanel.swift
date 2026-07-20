import AppKit
import SwiftUI

// A preset scale for the switcher overlay. A single multiplier drives the
// font, icons, and spacing together (see SwitcherMetrics), so the whole
// overlay grows or shrinks as one instead of leaving text clipped inside a
// fixed row.
enum SwitcherSize: String, CaseIterable, Identifiable {
    case small
    case medium = "default"
    case large
    case extraLarge

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small: return 0.85
        case .medium: return 1
        case .large: return 1.2
        case .extraLarge: return 1.4
        }
    }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Default"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
}

// Every switcher dimension derives from one scale, so SwitcherView and the
// panel's manual layout() cannot drift apart: change the scale and the text,
// icons, padding, and the panel frame all move together. The base
// (scale = 1) values reproduce the original fixed layout.
struct SwitcherMetrics {
    let scale: CGFloat

    static var current: SwitcherMetrics {
        SwitcherMetrics(scale: Settings.switcherSize.scale)
    }

    var iconSize: CGFloat { 18 * scale }
    var titleFontSize: CGFloat { 13 * scale }
    var annotationFontSize: CGFloat { 11 * scale }
    var annotationSpacing: CGFloat { 12 * scale }
    var rowHorizontalPadding: CGFloat { 10 * scale }
    var rowVerticalPadding: CGFloat { 5 * scale }
    var rowCornerRadius: CGFloat { 6 * scale }
    var rowSpacing: CGFloat { 2 * scale }
    var contentPadding: CGFloat { 8 * scale }
    var panelCornerRadius: CGFloat { 12 * scale }
    var width: CGFloat { 520 * scale }
    var maxHeight: CGFloat { 560 * scale }

    // The height the panel reserves per row: the icon (taller than the
    // title's line box) plus the row's vertical padding. This is the value
    // the manual layout must keep in step with the SwitcherView row -
    // undercount it and the content overflows the window as the list grows.
    var rowHeight: CGFloat { iconSize + rowVerticalPadding * 2 }
}

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
    let metrics: SwitcherMetrics

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                        HStack {
                            if let icon = row.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                            }
                            (Text(row.title)
                                .font(.system(size: metrics.titleFontSize, weight: .semibold))
                                + Text(row.subtitle.map { " - \($0)" } ?? "")
                                .font(.system(size: metrics.titleFontSize)))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: metrics.annotationSpacing)
                            if let annotation = row.annotation {
                                Text(annotation)
                                    .font(.system(size: metrics.annotationFontSize))
                                    .foregroundColor(index == model.selected ? .white.opacity(0.8) : .secondary)
                            }
                        }
                        .padding(.horizontal, metrics.rowHorizontalPadding)
                        .padding(.vertical, metrics.rowVerticalPadding)
                        .background(index == model.selected ? Color.accentColor : Color.clear)
                        .foregroundColor(index == model.selected ? .white : .primary)
                        .cornerRadius(metrics.rowCornerRadius)
                        .id(index)
                    }
                }
                .padding(metrics.contentPadding)
            }
            .onChange(of: model.selected) { newValue in
                proxy.scrollTo(newValue)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(metrics.panelCornerRadius)
    }
}

// Non-activating borderless panel: it must never become the active app, or
// the MRU order (and "previous app" quick switching) would corrupt itself.
final class SwitcherPanel {
    private var panel: NSPanel
    private let model = SwitcherViewModel()
    private var lastOrderedFront = Date.distantPast

    // The active size preset. SwitcherMetrics derives every dimension the
    // manual layout() below shares with SwitcherView from one scale, so the
    // two cannot drift and overflow the window. Refreshed at each show() (a
    // session boundary); a mid-session rebuild reuses the live metrics so
    // the panel never resizes underfoot.
    private var metrics = SwitcherMetrics.current

    init() {
        panel = Self.makePanel(model: model, metrics: metrics)
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
            // close() is what releases the replaced panel (release-when-
            // closed is off); without it the panel and its live SwiftUI
            // tree survive every topology change and keep rendering.
            self.panel.close()
            self.panel = Self.makePanel(model: self.model, metrics: self.metrics)
            if wasVisible {
                self.layout()
                self.panel.orderFrontRegardless()
                self.lastOrderedFront = Date()
            }
        }
    }

    private static func makePanel(model: SwitcherViewModel, metrics: SwitcherMetrics) -> NSPanel {
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
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model, metrics: metrics))
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
    // The debug timing covers the on-screen probe and ordering, not the
    // deferred SwiftUI render - it answers "does the per-press WindowServer
    // round trip cost anything" (issue #37).
    func select(index: Int) {
        let started = Date()
        model.selected = index
        show()
        Log.debug("panel: select \(Int(Date().timeIntervalSince(started) * 1000))ms rows=\(model.rows.count)")
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
        metrics = SwitcherMetrics.current
        panel = Self.makePanel(model: model, metrics: metrics)
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let rows = CGFloat(model.rows.count)
        let content = rows * metrics.rowHeight + max(0, rows - 1) * metrics.rowSpacing
            + metrics.contentPadding * 2
        // A tall list scrolls inside the panel; never let the largest preset
        // grow the window past the screen it is centered on.
        let height = min(content, metrics.maxHeight, frame.height - 48)
        let origin = NSPoint(x: frame.midX - metrics.width / 2, y: frame.midY - height / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: metrics.width, height: height)), display: true)
    }
}
