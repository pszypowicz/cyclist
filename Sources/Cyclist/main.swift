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
      --heal-experiment        Judge the fullscreen toolbar band on the
                               Space that is on screen (#63), optionally
                               applying one heal candidate and re-judging.
        --heal <name>          Heal to apply; omit to judge only.
                               One of: \(WedgeHeals.names.joined(separator: ", "))
        --delay <seconds>      Countdown before judging (default: 6), so
                               the wedged Space can be brought on screen.
    """)
    exit(0)
}
if arguments.contains("--measure-swipe-floor") {
    SwipeFloorExperiment.run()
}
if arguments.contains("--heal-experiment") {
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    WedgeHealExperiment.run(heal: value(after: "--heal"),
                            delay: value(after: "--delay").flatMap(Int.init) ?? 6)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
