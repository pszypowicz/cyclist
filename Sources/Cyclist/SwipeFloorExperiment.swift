import AppKit

// Measures the compositor wedge floor: how soon after a verified Space
// arrival the next dock swipe may be posted before the WindowServer stops
// compositing the arrived Space (bookkeeping stays healthy while the
// screen shows bare wallpaper). The pacing constants in SpaceNavigator
// come from this measurement; rerun it with
//
//   /Applications/Cyclist.app/Contents/MacOS/Cyclist --measure-swipe-floor
//
// after a macOS update to revalidate them. Runs from the app binary (not
// a script) because judging the wedge needs real pixels, and the Screen
// Recording grant belongs to the app bundle. The display flips rapidly
// between the current Space and its neighbor for the duration (about a
// minute); the run aborts if a wedge fails to recover.
enum SwipeFloorExperiment {
    // Post-after-arrival gaps to sweep, milliseconds, longest first so the
    // run starts safe and walks toward the cliff.
    private static let gaps = [700, 500, 350, 250, 150, 100, 50, 25, 0]
    private static let transitionsPerBurst = 6
    private static let trialsPerGap = 2

    static func run() -> Never {
        guard CGPreflightScreenCaptureAccess() else {
            print("Screen Recording not granted; pixel verdicts are impossible.")
            exit(1)
        }
        guard let info = Spaces.activeDisplayInfo(), info.order.count >= 2,
              let currentIndex = info.order.firstIndex(of: info.current) else {
            print("Need at least two Spaces on the active display.")
            exit(1)
        }
        let neighborIndex = currentIndex + (currentIndex + 1 < info.order.count ? 1 : -1)
        let home = info.current
        let away = info.order[neighborIndex]
        let awayIsRight = neighborIndex > currentIndex
        print("flipping between space \(home) and space \(away)")

        var lastSafeGap: Int?
        var firstWedgedGap: Int?
        for gap in gaps {
            var wedged = false
            for trial in 1...trialsPerGap {
                let result = burst(home: home, away: away, awayIsRight: awayIsRight, gapMs: gap)
                print("gap=\(gap)ms trial=\(trial): \(result.summary)")
                if result.wedged {
                    wedged = true
                    guard recover(home: home, away: away, awayIsRight: awayIsRight) else {
                        print("wedge did not recover; aborting")
                        exit(1)
                    }
                    break
                }
            }
            if wedged {
                firstWedgedGap = gap
                break
            }
            lastSafeGap = gap
        }
        print("RESULT: last safe gap=\(lastSafeGap.map { "\($0)ms" } ?? "none"),"
            + " first wedged gap=\(firstWedgedGap.map { "\($0)ms" } ?? "none")")
        exit(0)
    }

    private struct BurstResult {
        let wedged: Bool
        let arrivals: [Int]  // post-to-bookkeeping-flip, ms
        let drops: Int

        var summary: String {
            let latency = arrivals.isEmpty ? "-"
                : "\(arrivals.min()!)-\(arrivals.max()!)ms (avg \(arrivals.reduce(0, +) / arrivals.count)ms)"
            return "\(wedged ? "WEDGED" : "clean") arrivals=\(latency) drops=\(drops)"
        }
    }

    // Alternate between the two Spaces, posting each swipe `gapMs` after
    // the previous transition was observed in the bookkeeping.
    private static func burst(home: UInt64, away: UInt64, awayIsRight: Bool, gapMs: Int) -> BurstResult {
        var arrivals: [Int] = []
        var drops = 0
        var target = away
        for _ in 0..<transitionsPerBurst {
            let right = (target == away) == awayIsRight
            let posted = Date()
            Spaces.postDockSwipes(right: right, steps: 1)
            if awaitCurrentSpace(target, timeoutMs: 1000) {
                arrivals.append(Int(Date().timeIntervalSince(posted) * 1000))
            } else {
                drops += 1
            }
            usleep(UInt32(gapMs) * 1000)
            target = target == away ? home : away
        }
        // Settle, then let pixels judge the Space actually on screen.
        usleep(1_200_000)
        let wedged = Diagnostics.isComposited(space: currentSpace() ?? home) == false
        return BurstResult(wedged: wedged, arrivals: arrivals, drops: drops)
    }

    // Polls the bookkeeping until the Space flips (5ms quantization);
    // false when the swipe was dropped.
    private static func awaitCurrentSpace(_ target: UInt64, timeoutMs: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if currentSpace() == target {
                return true
            }
            usleep(5000)
        }
        return false
    }

    private static func currentSpace() -> UInt64? {
        Spaces.activeDisplayInfo()?.current
    }

    // A wedge clears with one clean, slow transition pair.
    private static func recover(home: UInt64, away: UInt64, awayIsRight: Bool) -> Bool {
        for _ in 0..<2 {
            sleep(2)
            if currentSpace() != away {
                Spaces.postDockSwipes(right: awayIsRight, steps: 1)
                _ = awaitCurrentSpace(away, timeoutMs: 1500)
            }
            sleep(2)
            Spaces.postDockSwipes(right: !awayIsRight, steps: 1)
            _ = awaitCurrentSpace(home, timeoutMs: 1500)
            sleep(1)
            if Diagnostics.isComposited(space: currentSpace() ?? home) != false {
                print("recovered")
                return true
            }
        }
        return false
    }
}
