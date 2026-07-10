import Foundation

// Beta diagnostics. NSLog from this app does not reliably reach the unified
// log, so a plain file it is: ~/Library/Logs/Cyclist.log
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Cyclist.log")
    private static let timestamp = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = "\(timestamp.string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
