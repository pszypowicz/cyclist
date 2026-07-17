import AppKit
import SwiftUI

// On-screen input feedback for screen recordings (the demoHud default):
// every trigger Cyclist consumes - hotkey presses and trackpad swipes -
// flashes briefly at the bottom of the active display. External keystroke
// visualizers cannot show these inputs: the active tap consumes them
// before downstream listeners see them, and nothing external reads the
// gesture stream at all. Flashing from the handling path keeps the
// overlay truthful - it shows exactly what Cyclist acted on.
final class DemoHUD {
    static let shared = DemoHUD()

    private final class Model: ObservableObject {
        @Published var text = ""
        @Published var detail: String?
    }

    private struct HUDView: View {
        @ObservedObject var model: Model

        var body: some View {
            VStack(spacing: 3) {
                Text(model.text)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                if let detail = model.detail {
                    Text(detail)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.72))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var lastText = ""
    private var lastDetail: String?
    private var repeats = 0
    private let linger: TimeInterval = 1.2

    private let width: CGFloat = 640
    private let height: CGFloat = 120
    private let bottomInset: CGFloat = 100

    // Main thread only. `detail` is a smaller second line - chain
    // navigation puts the transition it performs there ("workspace 2 →
    // Safari (fullscreen)"). A repeat of the still-visible trigger
    // collapses into a count ("⌘⇥ ×3") instead of an unreadable restart.
    func flash(_ text: String, detail: String? = nil) {
        guard Settings.demoHud else { return }
        let visible = hideWork != nil
        hideWork?.cancel()
        if visible, text == lastText, detail == lastDetail {
            repeats += 1
        } else {
            repeats = 1
        }
        lastText = text
        lastDetail = detail
        model.text = repeats > 1 ? "\(text) ×\(repeats)" : text
        model.detail = detail
        if !visible {
            // Hidden, or mid-fade: an in-flight alpha animation cannot be
            // reclaimed, and a fresh window is a few milliseconds (the
            // same trade SwitcherPanel.show makes).
            dismissPanel()
            panel = makePanel()
            panel?.orderFrontRegardless()
        }
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    private func fadeOut() {
        hideWork = nil
        lastText = ""
        lastDetail = nil
        repeats = 0
        guard let fading = panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            fading.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A flash during the fade already replaced the panel; only the
            // undisturbed fade releases it.
            guard let self, self.panel === fading, self.hideWork == nil else { return }
            self.dismissPanel()
        })
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        // close() is what releases the panel (release-when-closed is off,
        // as in SwitcherPanel).
        panel?.close()
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: frame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The rounded box draws its own soft shadow; the window shadow
        // would leave a stale outline when the text width changes.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // After isFloatingPanel, which would reset it to .floating: the
        // flash must never sit under the window it announces leaving.
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        // Stationary and on every Space, so the flash survives the very
        // Space transition it announces.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    private func frame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let visible = screen.visibleFrame
        return NSRect(x: visible.midX - width / 2, y: visible.minY + bottomInset,
                      width: width, height: height)
    }
}
