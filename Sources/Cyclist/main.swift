import AppKit

// CLI mode: post the instant Space-switch gestures and exit, without
// starting the app. Lets other tools (e.g. a Hammerspoon workspace chain)
// reuse Cyclist's switching engine. CGEvent posting is authorized through
// the caller's Accessibility grant (child processes inherit the invoking
// app's TCC responsibility).
let arguments = CommandLine.arguments
if let flagIndex = arguments.firstIndex(of: "--goto-space") {
    guard arguments.count > flagIndex + 1, let spaceID = UInt64(arguments[flagIndex + 1]) else {
        FileHandle.standardError.write(Data("usage: Cyclist --goto-space <space-id>\n".utf8))
        exit(2)
    }
    guard let info = Spaces.orderInfo(containing: spaceID),
          let targetIndex = info.order.firstIndex(of: spaceID),
          let currentIndex = info.order.firstIndex(of: info.current) else {
        FileHandle.standardError.write(Data("Cyclist: unknown Space id \(spaceID)\n".utf8))
        exit(1)
    }
    let steps = targetIndex - currentIndex
    if steps != 0 {
        Spaces.postDockSwipes(right: steps > 0, steps: abs(steps))
    }
    exit(0)
}
if arguments.contains("-h") || arguments.contains("--help") {
    print("""
    Cyclist - text-only Cmd+Tab switcher for macOS.

    Run without arguments to start the app (menu bar, keyboard hooks).

    Flags:
      --goto-space <space-id>  Switch to the given native Space instantly
                               (CGS Space id, as reported by the private
                               CGSCopyManagedDisplaySpaces API or
                               Hammerspoon's hs.spaces) and exit.
      -h, --help               Show this help.
    """)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
