import Foundation

// Thin wrapper around the AeroSpace CLI. AeroSpace is optional: when the
// binary is missing (or a command fails) callers fall back to plain native
// Space navigation.
enum Aerospace {
    private static let binary = "/opt/homebrew/bin/aerospace"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: binary)
    }

    static func run(_ arguments: [String]) -> String? {
        guard isAvailable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
