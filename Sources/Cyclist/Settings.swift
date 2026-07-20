import Foundation

// Every setting lives in standard user defaults, so the Settings window
// and `defaults write cz.szypowi.cyclist ...` are the same
// mechanism - external writes apply to the running app via KVO
// (AppDelegate observes the keys with side effects - the AeroSpace
// bridge and the menu bar icon; the shortcut store below re-parses its
// own).
enum Settings {
    static let appSwitcherKey = "appSwitcher"
    static let windowSwitcherKey = "windowSwitcher"
    static let showHiddenAppsKey = "showHiddenApps"
    static let showMinimizedWindowsKey = "showMinimizedWindows"
    static let showWindowsInOtherSpacesKey = "showWindowsInOtherSpaces"
    static let showAppsWithNoWindowKey = "showAppsWithNoWindow"
    static let liveOtherSpaceTitlesKey = "liveOtherSpaceTitles"
    static let trackpadSwipeKey = "trackpadSwipe"
    static let keyboardSpaceNavKey = "keyboardSpaceNavigation"
    static let showMenuBarIconKey = "showMenuBarIcon"
    static let aerospaceIntegrationKey = "aerospaceIntegration"
    static let aerospaceFollowWorkspaceKey = "aerospaceFollowWorkspace"
    static let showHollowWorkspacesKey = "showHollowWorkspaces"
    static let switcherSizeKey = "switcherSize"
    static let demoHudKey = "demoHud"
    static let switchAppsShortcutKey = "switchAppsShortcut"
    static let switchWindowsShortcutKey = "switchWindowsShortcut"
    static let previousSpaceShortcutKey = "previousSpaceShortcut"
    static let nextSpaceShortcutKey = "nextSpaceShortcut"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            appSwitcherKey: true,
            windowSwitcherKey: true,
            showHiddenAppsKey: true,
            showMinimizedWindowsKey: true,
            showWindowsInOtherSpacesKey: true,
            showAppsWithNoWindowKey: false,
            liveOtherSpaceTitlesKey: false,
            trackpadSwipeKey: true,
            keyboardSpaceNavKey: true,
            showMenuBarIconKey: true,
            aerospaceIntegrationKey: false,
            aerospaceFollowWorkspaceKey: true,
            showHollowWorkspacesKey: false,
            switcherSizeKey: SwitcherSize.medium.rawValue,
            demoHudKey: false,
            switchAppsShortcutKey: "cmd+tab",
            switchWindowsShortcutKey: "cmd+backtick",
            previousSpaceShortcutKey: "ctrl+left",
            nextSpaceShortcutKey: "ctrl+right",
        ])
    }

    static var appSwitcher: Bool {
        UserDefaults.standard.bool(forKey: appSwitcherKey)
    }

    static var windowSwitcher: Bool {
        UserDefaults.standard.bool(forKey: windowSwitcherKey)
    }

    static var showHiddenApps: Bool {
        UserDefaults.standard.bool(forKey: showHiddenAppsKey)
    }

    static var showMinimizedWindows: Bool {
        UserDefaults.standard.bool(forKey: showMinimizedWindowsKey)
    }

    static var showWindowsInOtherSpaces: Bool {
        UserDefaults.standard.bool(forKey: showWindowsInOtherSpacesKey)
    }

    static var showAppsWithNoWindow: Bool {
        UserDefaults.standard.bool(forKey: showAppsWithNoWindowKey)
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

    static var aerospaceFollowWorkspace: Bool {
        UserDefaults.standard.bool(forKey: aerospaceFollowWorkspaceKey)
    }

    static var showHollowWorkspaces: Bool {
        UserDefaults.standard.bool(forKey: showHollowWorkspacesKey)
    }

    // Falls back to the default preset for a missing or garbage `defaults
    // write` value rather than failing - an unreadable size is cosmetic,
    // not the load-bearing hazard a bad shortcut string is.
    static var switcherSize: SwitcherSize {
        let raw = UserDefaults.standard.string(forKey: switcherSizeKey)
        return raw.flatMap(SwitcherSize.init(rawValue:)) ?? .medium
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

    private(set) var switchApps: Shortcut
    private(set) var switchWindows: Shortcut
    private(set) var previousSpace: Shortcut
    private(set) var nextSpace: Shortcut

    // Keyed by defaults key - what the recorder's duplicate check walks.
    var all: [String: Shortcut] {
        [
            Settings.switchAppsShortcutKey: switchApps,
            Settings.switchWindowsShortcutKey: switchWindows,
            Settings.previousSpaceShortcutKey: previousSpace,
            Settings.nextSpaceShortcutKey: nextSpace,
        ]
    }

    private static let keys = [
        Settings.switchAppsShortcutKey, Settings.switchWindowsShortcutKey,
        Settings.previousSpaceShortcutKey, Settings.nextSpaceShortcutKey,
    ]

    override private init() {
        switchApps = Self.read(Settings.switchAppsShortcutKey)
        switchWindows = Self.read(Settings.switchWindowsShortcutKey)
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
            switchApps = Self.read(Settings.switchAppsShortcutKey)
            switchWindows = Self.read(Settings.switchWindowsShortcutKey)
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
