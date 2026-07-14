import Foundation

enum Settings {
    static let includeHiddenKey = "includeHidden"
    static let includeMinimizedKey = "includeMinimized"
    static let includeOtherSpacesKey = "includeOtherSpaces"
    static let includeNoWindowsKey = "includeNoWindows"
    static let aerospaceIntegrationKey = "aerospaceIntegration"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            includeHiddenKey: true,
            includeMinimizedKey: true,
            includeOtherSpacesKey: true,
            includeNoWindowsKey: false,
            aerospaceIntegrationKey: true,
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

    static var aerospaceIntegration: Bool {
        UserDefaults.standard.bool(forKey: aerospaceIntegrationKey)
    }
}
