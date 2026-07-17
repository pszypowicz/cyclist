import Combine
import CoreGraphics
import Foundation

// Captures the next key press through the app's own event tap - the only
// place combos like Cmd+Tab are visible at all (they never reach a local
// key monitor) - and stores it in user defaults. While a recording is
// active the tap hands every keyDown here and consumes it.
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    // Defaults key being recorded; nil when idle.
    @Published private(set) var recordingKey: String?
    @Published private(set) var message: String?

    static let labels: [String: String] = [
        Settings.switcherShortcutKey: "Open switcher",
        Settings.cycleWindowsShortcutKey: "Cycle app windows",
        Settings.previousSpaceShortcutKey: "Previous Space",
        Settings.nextSpaceShortcutKey: "Next Space",
    ]

    var isRecording: Bool { recordingKey != nil }

    // Clicking the active row again cancels, so a recording started while
    // the tap is down (Cyclist disabled) can always be backed out of.
    func begin(key: String) {
        message = nil
        recordingKey = recordingKey == key ? nil : key
    }

    // Also called when the Settings window closes or resigns key and when
    // the taps tear down: an armed recording swallows every keyDown
    // system-wide, so it must not outlive the UI that shows it.
    func cancel() {
        recordingKey = nil
    }

    // Called from the tap callback for every keyDown while recording;
    // always consumes so half-typed combos never leak to the focused app.
    // State changes hop off the callback before touching SwiftUI.
    func consume(keyCode: Int64, flags: CGEventFlags) -> Bool {
        DispatchQueue.main.async { [self] in finish(keyCode: keyCode, flags: flags) }
        return true
    }

    private func finish(keyCode: Int64, flags: CGEventFlags) {
        guard let key = recordingKey else { return }
        if keyCode == 53 { // Escape cancels
            recordingKey = nil
            return
        }
        // Shift alone cannot carry a binding: it is the reverse key while
        // a binding is active, and matching ignores it.
        let modifiers = Shortcut.normalized(flags).subtracting(.shift)
        guard !modifiers.isEmpty else {
            message = "Include cmd, alt, or ctrl (shift alone is the reverse key)."
            return
        }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers)
        // Compare shift-stripped, the same way matches() does: a stored
        // cmd+shift+tab and a recorded cmd+tab collide at match time even
        // though they are not equal.
        for (otherKey, other) in ShortcutSettings.shared.all where otherKey != key {
            if other.keyCode == shortcut.keyCode,
               other.modifiers.subtracting(.shift) == shortcut.modifiers {
                message = "\(shortcut.display) is already \(Self.labels[otherKey] ?? otherKey)."
                return
            }
        }
        recordingKey = nil
        UserDefaults.standard.set(shortcut.settingString, forKey: key)
        Log.write("shortcut recorded: \(key) = \(shortcut.settingString)")
    }
}
