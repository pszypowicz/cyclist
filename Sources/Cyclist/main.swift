import AppKit

let arguments = CommandLine.arguments
if arguments.contains("-h") || arguments.contains("--help") {
    print("""
    Cyclist - text-only Cmd+Tab switcher for macOS.

    Run without arguments to start the app (menu bar, keyboard hooks).

    Flags:
      -h, --help               Show this help.
      --measure-swipe-floor    Measure the compositor wedge floor by
                               flipping Spaces in pixel-judged bursts
                               (takes over the display for ~1 minute).
    """)
    exit(0)
}
if arguments.contains("--measure-swipe-floor") {
    SwipeFloorExperiment.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
