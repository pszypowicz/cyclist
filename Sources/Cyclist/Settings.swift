import Foundation

enum Settings {
    static let includeHiddenKey = "includeHidden"
    static let includeMinimizedKey = "includeMinimized"
    static let includeOtherSpacesKey = "includeOtherSpaces"
    static let includeNoWindowsKey = "includeNoWindows"
    static let trackpadSwipeKey = "trackpadSwipe"
    static let keyboardSpaceNavKey = "keyboardSpaceNavigation"
    static let enabledKey = "enabled"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            includeHiddenKey: true,
            includeMinimizedKey: true,
            includeOtherSpacesKey: true,
            includeNoWindowsKey: false,
            trackpadSwipeKey: true,
            keyboardSpaceNavKey: true,
            enabledKey: true,
        ])
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

    static var trackpadSwipe: Bool {
        UserDefaults.standard.bool(forKey: trackpadSwipeKey)
    }

    static var keyboardSpaceNav: Bool {
        UserDefaults.standard.bool(forKey: keyboardSpaceNavKey)
    }

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }
}
