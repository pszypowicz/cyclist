import AppKit

let arguments = CommandLine.arguments
if arguments.contains("-h") || arguments.contains("--help") {
    print("""
    Cyclist - text-only Cmd+Tab switcher for macOS.

    Run without arguments to start the app (menu bar, keyboard hooks).

    Flags:
      -h, --help               Show this help.
    """)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
