import AppKit

// File-driven configuration for the settings that belong in dotfiles
// rather than a menu (the AeroSpace-related ones):
//
//   ${XDG_CONFIG_HOME:-~/.config}/cyclist/cyclist.toml
//
// The accepted grammar is a TOML subset: `[section]` headers,
// `key = true|false` lines, and `#` comments. Unreadable lines and
// unknown keys are logged at default level and skipped - a typo must
// surface, not silently revert a setting to its default. Cyclist never
// writes the file, so hand-written comments and formatting are safe.
//
// Edits apply live: dispatch sources watch the cyclist directory (the
// directory, not the file, so editors that save by rename-and-replace
// still trigger) and, when the file is a symlink into somewhere else
// (stow-managed dotfiles), the resolved target's directory too - edits
// there never touch the watched config directory. The watch set re-arms
// after every reload, so replacing the file with a symlink (or back)
// keeps working. When no watched directory exists at launch there is
// nothing to watch and a created file needs an app restart to be seen.
enum Config {
    struct Values: Equatable {
        var aerospaceIntegration = false
        var showHollowWorkspaces = false
    }

    private(set) static var values = Values()

    static var aerospaceIntegration: Bool { values.aerospaceIntegration }
    static var showHollowWorkspaces: Bool { values.showHollowWorkspaces }

    private static var watchers: [DispatchSourceFileSystemObject] = []
    private static var reloadWork: DispatchWorkItem?

    static func load() {
        values = read()
        let source = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL.path : "defaults"
        Log.write("config: \(describe(values)) (\(source))")
    }

    static func startWatching(onChange: @escaping (_ old: Values, _ new: Values) -> Void) {
        armWatchers(onChange)
        if watchers.isEmpty {
            Log.write("config: \(directoryURL.path) absent; a config file created later needs an app restart")
        }
    }

    private static func armWatchers(_ onChange: @escaping (_ old: Values, _ new: Values) -> Void) {
        for watcher in watchers {
            watcher.cancel()
        }
        watchers = []
        var directories = [directoryURL.resolvingSymlinksInPath().path]
        let resolvedParent = fileURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        if resolvedParent != directories[0] {
            directories.append(resolvedParent)
        }
        for directory in directories {
            let fd = open(directory, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { scheduleReload(onChange) }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    // Editors fire several filesystem events per save; one re-read after
    // the burst settles is enough.
    private static func scheduleReload(_ onChange: @escaping (_ old: Values, _ new: Values) -> Void) {
        reloadWork?.cancel()
        let work = DispatchWorkItem {
            let old = values
            let new = read()
            // The file may have moved between a real file and a symlink;
            // follow wherever it points now.
            armWatchers(onChange)
            guard new != old else { return }
            values = new
            Log.write("config: reloaded - \(describe(new))")
            onChange(old, new)
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // XDG base directory spec: XDG_CONFIG_HOME counts only when absolute.
    // GUI launches rarely carry it at all (launchd provides the
    // environment, not the shell), making ~/.config the effective home.
    private static var directoryURL: URL {
        let env = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = env?.hasPrefix("/") == true
            ? URL(fileURLWithPath: env!)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("cyclist")
    }

    private static var fileURL: URL { directoryURL.appendingPathComponent("cyclist.toml") }

    private static func read() -> Values {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return Values() }
        var result = Values()
        var section = ""
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let uncommented = rawLine[..<(rawLine.firstIndex(of: "#") ?? rawLine.endIndex)]
            let line = uncommented.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  let value = Bool(parts[1].trimmingCharacters(in: .whitespaces)) else {
                Log.write("config: \(fileURL.lastPathComponent):\(index + 1) unreadable: \(line)")
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            switch section.isEmpty ? key : "\(section).\(key)" {
            case "aerospace.integration":
                result.aerospaceIntegration = value
            case "aerospace.show-hollow-workspaces":
                result.showHollowWorkspaces = value
            default:
                Log.write("config: \(fileURL.lastPathComponent):\(index + 1) unknown key: "
                    + (section.isEmpty ? key : "\(section).\(key)"))
            }
        }
        return result
    }

    private static func describe(_ values: Values) -> String {
        "aerospace.integration=\(values.aerospaceIntegration)"
            + " aerospace.show-hollow-workspaces=\(values.showHollowWorkspaces)"
    }
}
