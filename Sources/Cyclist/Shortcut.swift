import CoreGraphics

// A recorded key combination: a keycode plus the exact set of held
// modifiers. Serialized as "cmd+tab" (modifier names and a key name
// joined with "+") in user defaults; unknown keycodes round-trip as
// "code<N>" so any physical key stays recordable.
struct Shortcut: Equatable {
    var keyCode: Int64
    var modifiers: Modifiers

    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
    }

    static func normalized(_ flags: CGEventFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }

    // Shift reverses the direction while a binding is active, so matching
    // ignores it: cmd+shift+tab matches the cmd+tab binding.
    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode
            && Self.normalized(flags).subtracting(.shift) == modifiers.subtracting(.shift)
    }

    static func parse(_ string: String) -> Shortcut? {
        var modifiers: Modifiers = []
        var keyCode: Int64?
        for token in string.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let modifier = modifierNames[token] {
                modifiers.insert(modifier)
            } else if let code = codesByName[token] {
                guard keyCode == nil else { return nil }
                keyCode = code
            } else if token.hasPrefix("code"), let code = Int64(token.dropFirst(4)), code >= 0 {
                guard keyCode == nil else { return nil }
                keyCode = code
            } else {
                return nil
            }
        }
        guard let keyCode else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    var settingString: String {
        var tokens: [String] = []
        if modifiers.contains(.command) { tokens.append("cmd") }
        if modifiers.contains(.option) { tokens.append("alt") }
        if modifiers.contains(.control) { tokens.append("ctrl") }
        if modifiers.contains(.shift) { tokens.append("shift") }
        tokens.append(Self.namesByCode[keyCode] ?? "code\(keyCode)")
        return tokens.joined(separator: "+")
    }

    // Menu-style rendering: modifier symbols in Apple's canonical order,
    // then the key.
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        if let symbol = Self.displaySymbols[keyCode] {
            return text + symbol
        }
        let name = Self.namesByCode[keyCode] ?? "code\(keyCode)"
        return text + (name.count == 1 ? name.uppercased() : name.capitalized)
    }

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command,
        "alt": .option, "opt": .option, "option": .option,
        "ctrl": .control, "control": .control,
        "shift": .shift,
    ]

    private static let namesByCode: [Int64: String] = [
        48: "tab", 50: "backtick", 36: "return", 49: "space", 51: "delete", 53: "escape",
        123: "left", 124: "right", 125: "down", 126: "up",
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
        40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s",
        17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
        27: "minus", 24: "equals", 33: "leftbracket", 30: "rightbracket",
        41: "semicolon", 39: "quote", 43: "comma", 47: "period", 44: "slash", 42: "backslash",
    ]

    private static let codesByName: [String: Int64] =
        Dictionary(uniqueKeysWithValues: namesByCode.map { ($1, $0) })

    private static let displaySymbols: [Int64: String] = [
        48: "⇥", 50: "`", 36: "↩", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
