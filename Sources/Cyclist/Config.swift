import AppKit

// File-driven configuration for the settings that belong in dotfiles
// rather than a menu (the AeroSpace-related ones):
//
//   ${XDG_CONFIG_HOME:-~/.config}/cyclist/cyclist.toml
//
// The accepted grammar is a TOML subset: `[section]` headers,
// `key = true|false` lines, and `#` comments. Unreadable lines and
// unknown keys are logged at default level and skipped - a typo must
// surface, not silently revert a setting to its default. The Settings
// window writes through set(_:key:to:), a surgical line edit that leaves
// every other byte of the file alone, so hand-written comments and
// formatting are safe.
//
// Edits apply live: dispatch sources watch the cyclist directory (the
// directory, not the file, so editors that save by rename-and-replace
// still trigger) and, when the file is a symlink into somewhere else
// (stow-managed dotfiles), the resolved target's directory too - edits
// there never touch the watched config directory. The watch set re-arms
// after every reload, so replacing the file with a symlink (or back)
// keeps working. A missing file is created from a commented template at
// startup, so the directory always exists to watch and the config
// surface is discoverable on disk from the first run.
enum Config {
    struct Values: Equatable {
        var aerospaceIntegration = false
        var showHollowWorkspaces = false
    }

    private(set) static var values = Values()

    static var aerospaceIntegration: Bool { values.aerospaceIntegration }
    static var showHollowWorkspaces: Bool { values.showHollowWorkspaces }

    // Posted after values change, whatever the writer (hand edit or the
    // Settings window); the Settings window resyncs its toggles on it.
    static let didChangeNotification = Notification.Name("CyclistConfigDidChange")

    private static var watchers: [DispatchSourceFileSystemObject] = []
    private static var reloadWork: DispatchWorkItem?
    private static var changeHandler: ((_ old: Values, _ new: Values) -> Void)?

    static func load() {
        ensureFileExists()
        values = read()
        let source = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL.path : "defaults"
        Log.write("config: \(describe(values)) (\(source))")
    }

    // Only creation is automatic; an existing file is never rewritten
    // outside set(...). The lstat-style existence check leaves a dangling
    // symlink (dotfiles whose target moved) alone rather than replacing
    // the link with a plain file.
    private static func ensureFileExists() {
        guard (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try (template + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            Log.write("config: created \(displayPath) from template")
        } catch {
            Log.write("config: could not create \(displayPath): \(error)")
        }
    }

    static func startWatching(onChange: @escaping (_ old: Values, _ new: Values) -> Void) {
        changeHandler = onChange
        armWatchers()
        if watchers.isEmpty {
            Log.write("config: \(directoryURL.path) unwatchable; edits need an app restart")
        }
    }

    private static func armWatchers() {
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
            source.setEventHandler { scheduleReload() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    // Editors fire several filesystem events per save; one re-read after
    // the burst settles is enough.
    private static func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem {
            let old = values
            let new = read()
            // The file may have moved between a real file and a symlink;
            // follow wherever it points now.
            armWatchers()
            guard new != old else { return }
            values = new
            Log.write("config: reloaded - \(describe(new))")
            changeHandler?(old, new)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // The Settings window's write path. A surgical line edit: only the
    // matched `key =` line changes (keeping any trailing comment), every
    // other byte survives, so a dotfiles-owned file stays hand-editable.
    // The write lands on the symlink's resolved target - an atomic write
    // on the symlink path itself would replace the link with a plain file.
    // The change is applied by the reload path, same as a hand edit.
    static func set(section: String, key: String, to value: Bool) {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? template
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try rewriting(text, section: section, key: key, value: value)
                .write(to: fileURL.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
        } catch {
            Log.write("config: write failed for \(section).\(key): \(error)")
            return
        }
        // A directory this write just created had no watcher to notice it;
        // reload directly instead of relying on one.
        scheduleReload()
    }

    private static func rewriting(_ text: String, section: String, key: String, value: Bool) -> String {
        var lines = text.components(separatedBy: "\n")
        var current = ""
        var insertAt: Int?
        for (index, raw) in lines.enumerated() {
            let uncommented = raw[..<(raw.firstIndex(of: "#") ?? raw.endIndex)]
            let line = uncommented.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if current == section { insertAt = index + 1 }
                continue
            }
            guard current == section else { continue }
            if !line.isEmpty { insertAt = index + 1 }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let comment = raw.firstIndex(of: "#").map { String(raw[$0...]) }
            lines[index] = "\(key) = \(value)" + (comment.map { " \($0)" } ?? "")
            return lines.joined(separator: "\n")
        }
        if let insertAt {
            lines.insert("\(key) = \(value)", at: insertAt)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            if !lines.isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines.append("\(key) = \(value)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // Seed for the first Settings-window write when no file exists yet;
    // mirrors the README example so the created file documents itself.
    private static let template = """
        [aerospace]
        # The AeroSpace bridge (socket client). Default: false.
        integration = false

        # Keep chain stops for workspaces whose windows all went native-fullscreen.
        # Default: false.
        show-hollow-workspaces = false
        """

    static var displayPath: String {
        (fileURL.path as NSString).abbreviatingWithTildeInPath
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
