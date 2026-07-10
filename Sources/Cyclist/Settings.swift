import Foundation

enum Settings {
    static let includeHiddenKey = "includeHidden"
    static let includeMinimizedKey = "includeMinimized"
    static let includeOtherSpacesKey = "includeOtherSpaces"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            includeHiddenKey: true,
            includeMinimizedKey: true,
            includeOtherSpacesKey: true,
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
}
