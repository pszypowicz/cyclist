import Foundation

// Every setting lives in standard user defaults, so the Settings window
// and `defaults write cz.szypowi.cyclist ...` are the same
// mechanism - external writes apply to the running app via KVO
// (AppDelegate observes the keys with side effects - the AeroSpace
// bridge and the menu bar icon; the shortcut store below re-parses its
// own).
enum Settings {
    static let appSwitcherKey = "appSwitcher"
    static let windowCyclerKey = "windowCycler"
    static let includeHiddenKey = "includeHidden"
    static let includeMinimizedKey = "includeMinimized"
    static let includeOtherSpacesKey = "includeOtherSpaces"
    static let includeNoWindowsKey = "includeNoWindows"
    static let liveOtherSpaceTitlesKey = "liveOtherSpaceTitles"
    static let trackpadSwipeKey = "trackpadSwipe"
    static let keyboardSpaceNavKey = "keyboardSpaceNavigation"
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let aerospaceIntegrationKey = "aerospaceIntegration"
    static let showHollowWorkspacesKey = "showHollowWorkspaces"
    static let demoHudKey = "demoHud"
    static let switcherShortcutKey = "switcherShortcut"
    static let cycleWindowsShortcutKey = "cycleWindowsShortcut"
    static let previousSpaceShortcutKey = "previousSpaceShortcut"
    static let nextSpaceShortcutKey = "nextSpaceShortcut"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            appSwitcherKey: true,
            windowCyclerKey: true,
            includeHiddenKey: true,
            includeMinimizedKey: true,
            includeOtherSpacesKey: true,
            includeNoWindowsKey: false,
            liveOtherSpaceTitlesKey: true,
            trackpadSwipeKey: true,
            keyboardSpaceNavKey: true,
            showMenuBarIconKey: true,
            aerospaceIntegrationKey: false,
            showHollowWorkspacesKey: false,
            demoHudKey: false,
            switcherShortcutKey: "cmd+tab",
            cycleWindowsShortcutKey: "cmd+backtick",
            previousSpaceShortcutKey: "ctrl+left",
            nextSpaceShortcutKey: "ctrl+right",
        ])
    }

    static var appSwitcher: Bool {
        UserDefaults.standard.bool(forKey: appSwitcherKey)
    }

    static var windowCycler: Bool {
        UserDefaults.standard.bool(forKey: windowCyclerKey)
    }

    static var includeHidden: Bool {
        UserDefaults.standard.bool(forKey: includeHiddenKey)
    }

    static var includeMinimized: Bool {
        UserDefaults.standard.bool(forKey: includeMinimizedKey)
    }

    static var includeOtherSpaces: Bool {
        UserDefaults.standard.bool(forKey: includeOtherSpacesKey)
    }

    static var includeNoWindows: Bool {
        UserDefaults.standard.bool(forKey: includeNoWindowsKey)
    }

    static var liveOtherSpaceTitles: Bool {
        UserDefaults.standard.bool(forKey: liveOtherSpaceTitlesKey)
    }

    static var trackpadSwipe: Bool {
        UserDefaults.standard.bool(forKey: trackpadSwipeKey)
    }

    static var keyboardSpaceNav: Bool {
        UserDefaults.standard.bool(forKey: keyboardSpaceNavKey)
    }

    static var showMenuBarIcon: Bool {
        UserDefaults.standard.bool(forKey: showMenuBarIconKey)
    }

    static var aerospaceIntegration: Bool {
        UserDefaults.standard.bool(forKey: aerospaceIntegrationKey)
    }

    static var showHollowWorkspaces: Bool {
        UserDefaults.standard.bool(forKey: showHollowWorkspacesKey)
    }

    static var demoHud: Bool {
        UserDefaults.standard.bool(forKey: demoHudKey)
    }
}

// The shortcut bindings, parsed once and re-parsed when their defaults
// change - parsing strings on the event-tap path would allocate per
// keystroke system-wide. KVO sees external `defaults write` too, so
// scripted rebinds apply live; the mutation hops to main because that is
// where the tap callbacks read. An unparseable or modifier-less string
// is a hard error: the recorder never writes one, so it can only come
// from a bad `defaults write`, and failing fast beats silently stealing
// a plain key or reverting to a default the user did not ask for.
final class ShortcutSettings: NSObject {
    static let shared = ShortcutSettings()

    private(set) var switcher: Shortcut
    private(set) var cycleWindows: Shortcut
    private(set) var previousSpace: Shortcut
    private(set) var nextSpace: Shortcut

    // Keyed by defaults key - what the recorder's duplicate check walks.
    var all: [String: Shortcut] {
        [
            Settings.switcherShortcutKey: switcher,
            Settings.cycleWindowsShortcutKey: cycleWindows,
            Settings.previousSpaceShortcutKey: previousSpace,
            Settings.nextSpaceShortcutKey: nextSpace,
        ]
    }

    private static let keys = [
        Settings.switcherShortcutKey, Settings.cycleWindowsShortcutKey,
        Settings.previousSpaceShortcutKey, Settings.nextSpaceShortcutKey,
    ]

    override private init() {
        switcher = Self.read(Settings.switcherShortcutKey)
        cycleWindows = Self.read(Settings.cycleWindowsShortcutKey)
        previousSpace = Self.read(Settings.previousSpaceShortcutKey)
        nextSpace = Self.read(Settings.nextSpaceShortcutKey)
        super.init()
        for key in Self.keys {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [self] in
            switcher = Self.read(Settings.switcherShortcutKey)
            cycleWindows = Self.read(Settings.cycleWindowsShortcutKey)
            previousSpace = Self.read(Settings.previousSpaceShortcutKey)
            nextSpace = Self.read(Settings.nextSpaceShortcutKey)
        }
    }

    private static func read(_ key: String) -> Shortcut {
        let string = UserDefaults.standard.string(forKey: key)!
        guard let shortcut = Shortcut.parse(string),
              !shortcut.modifiers.subtracting(.shift).isEmpty else {
            fatalError("defaults key \(key) holds no usable shortcut: \"\(string)\"")
        }
        return shortcut
    }
}
