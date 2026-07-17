import Foundation
import os

// Unified logging, subsystem = the bundle id. Operational lines log at
// default level and are always persisted. Diagnostic lines log at debug
// level, which the logging system discards for free until collection is
// armed:
//   log stream --level debug --predicate 'subsystem == "io.github.pszypowicz.Cyclist"'
// or persistently:
//   sudo log config --subsystem io.github.pszypowicz.Cyclist --mode "level:debug,persist:debug"
// Diagnostic-only WORK (pixel checks and the like) must also gate on
// `debugEnabled` so it costs nothing while collection is off.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.pszypowicz.Cyclist"
    private static let appLog = OSLog(subsystem: subsystem, category: "app")
    private static let diagnosticsLog = OSLog(subsystem: subsystem, category: "diagnostics")
    private static let app = Logger(appLog)
    private static let diagnostics = Logger(diagnosticsLog)

    static var debugEnabled: Bool { diagnosticsLog.isEnabled(type: .debug) }

    static func write(_ message: String) {
        app.log("\(message, privacy: .public)")
    }

    // The autoclosure keeps message construction free while debug
    // collection is off.
    static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let text = message()
        diagnostics.debug("\(text, privacy: .public)")
    }
}
