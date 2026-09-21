import AppKit

// Tests heal candidates for the fullscreen toolbar-band wedge (#63) from
// inside the app, where the Screen Recording grant lives: a shell process
// gets its TCC identity from the terminal, so scripts capture nothing and
// cannot judge the band.
//
// The band wedges white rather than black, unlike the purged main-window
// backing Diagnostics judges, so the verdict here is flatness rather than
// darkness. A drawn toolbar carries buttons, a title and a tab bar, which
// spread the pixel values; a wedged band is one uniform color across its
// whole width. Standard deviation separates the two with a wide margin.
enum WedgeHealExperiment {
    private typealias WindowCaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private typealias DisplayCaptureFn = @convention(c) (UInt32, CGRect) -> Unmanaged<CGImage>?
    private static let windowCapture = resolve("CGWindowListCreateImage", WindowCaptureFn.self)
    private static let displayCapture = resolve("CGDisplayCreateImageForRect", DisplayCaptureFn.self)

    // Below this spread the band carries no drawn content. Calibrated
    // against live runs: a drawn toolbar measures well above it, a wedged
    // band measures near zero.
    private static let flatnessThreshold = 3.0

    private static func resolve<T>(_ name: String, _ type: T.Type) -> T {
        unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)!, to: type)
    }

    static func run(heal: String?, delay: Int) {
        guard CGPreflightScreenCaptureAccess() else {
            print("Screen Recording is not granted to Cyclist; the band cannot be judged.")
            exit(1)
        }
        if let heal, !WedgeHeals.names.contains(heal) {
            print("Unknown heal \"\(heal)\". Available: \(WedgeHeals.names.joined(separator: ", "))")
            exit(1)
        }
        // The countdown is setup time: the Space has to be brought on
        // screen, and a healthy band needs Safari taken out of fullscreen
        // and put back. Nothing is measured until it runs out.
        for remaining in stride(from: delay, through: 1, by: -1) {
            print("Get the fullscreen Space you want judged on screen. Measuring in \(remaining)s...")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1)
        }
        // Then a short poll, because the band can take a moment to appear
        // after a fullscreen transition.
        let deadline = Date().addingTimeInterval(3)
        var found: (space: UInt64, band: Band)?
        repeat {
            if let info = Spaces.activeDisplayInfo(), let band = companionBand(space: info.current) {
                found = (info.current, band)
                break
            }
            usleep(300000)
        } while Date() < deadline

        guard let (space, band) = found else {
            print("No toolbar companion window appeared. Was a fullscreen Space on screen?")
            exit(1)
        }
        // A refused capture reads flat black, and so does an empty backing,
        // so a window known to be drawn is measured in the same run. Only
        // flat AND black condemns the capture: a legitimately blank window
        // reads flat and bright, which says nothing about the capture path.
        if let control = controlWindow(space: space), let reading = measure(control) {
            report("control", reading)
            if reading.wedged && reading.mean < 8 {
                print("The control window reads flat black as well, so the capture is "
                    + "not returning pixels. No verdict.")
                exit(1)
            }
        } else {
            print("control: none capturable; treat the verdict below with suspicion")
        }

        print("band: wid=\(band.id) pid=\(band.pid) bounds=\(band.bounds)")
        if let onScreen = measureScreen(band) {
            report("screen ", onScreen)
        }

        guard let before = measure(band) else {
            print("Cannot capture the band.")
            exit(1)
        }
        report("before", before)

        guard let heal else {
            print("VERDICT: \(before.wedged ? "WEDGED" : "drawn") (no heal applied)")
            exit(before.wedged ? 1 : 0)
        }
        guard before.wedged else {
            print("VERDICT: band is already drawn, nothing to heal. "
                + "Reproduce the wedge first, then re-run.")
            exit(0)
        }

        print("applying heal: \(heal) - \(WedgeHeals.describe(heal))")
        WedgeHeals.apply(heal, companionWindowID: band.id, companionBounds: band.bounds,
                         ownerPID: band.pid, space: space)

        // Give the owning app a moment to draw, then re-read the same band.
        Thread.sleep(forTimeInterval: 1.0)
        guard let after = measure(band) else {
            print("Cannot capture the band after the heal (the window may have gone).")
            exit(1)
        }
        report("after ", after)
        print("VERDICT: \(after.wedged ? "NOT HEALED" : "HEALED") by \(heal)")
        exit(after.wedged ? 1 : 0)
    }

    struct Band {
        let id: Int
        let pid: pid_t
        let bounds: CGRect
    }

    struct Reading {
        let mean: Double
        let deviation: Double
        var wedged: Bool { deviation < flatnessThreshold }
    }

    private static func report(_ label: String, _ reading: Reading) {
        print(String(format: "%@: mean=%.1f stddev=%.2f -> %@", label,
                     reading.mean, reading.deviation, reading.wedged ? "WEDGED" : "drawn"))
    }

    // The fullscreen toolbar companion. Geometry alone cannot name it: a
    // menu-bar replacement, the WindowServer's own menu bar and an ordinary
    // app's tab strip all span the display at the top too. The app already
    // draws the line that matters - Spaces.realWindows keeps the windows a
    // user can hold and rejects the fullscreen companions - so the band is
    // looked for among exactly the windows that predicate throws away.
    static func companionBand(space: UInt64) -> Band? {
        let displayBounds = CGDisplayBounds(Spaces.activeDisplayID() ?? CGMainDisplayID())
        let ids = Spaces.windowIDs(inSpace: space)
        guard !ids.isEmpty else { return nil }
        let companions = ids.subtracting(Spaces.realWindows(among: ids))
        guard !companions.isEmpty,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        for info in list {
            guard let windowID = info[kCGWindowNumber as String] as? Int,
                  companions.contains(windowID),
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // The toolbar band spans the display and is short. The backdrop
            // and shield companions cover the whole display instead.
            guard abs(bounds.width - displayBounds.width) < 2,
                  bounds.height > 20, bounds.height < 200 else { continue }
            return Band(id: windowID, pid: pid, bounds: bounds)
        }
        return nil
    }

    // The biggest window on the Space that the app counts as real: the
    // fullscreen content itself, which is drawn whenever the band is the
    // only thing wedged. Measuring it proves the capture path works.
    static func controlWindow(space: UInt64) -> Band? {
        let ids = Spaces.realWindows(among: Spaces.windowIDs(inSpace: space))
        guard !ids.isEmpty,
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: Band?
        for info in list {
            guard let windowID = info[kCGWindowNumber as String] as? Int,
                  ids.contains(windowID),
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 200, bounds.height >= 200 else { continue }
            let area = bounds.width * bounds.height
            if best == nil || area > best!.bounds.width * best!.bounds.height {
                best = Band(id: windowID, pid: pid, bounds: bounds)
            }
        }
        return best
    }

    // What the display actually shows across the band's strip, whoever drew
    // it. A band with an empty backing reads flat from the window capture
    // while the screen still shows whatever sits behind it.
    private static func measureScreen(_ band: Band) -> Reading? {
        let display = Spaces.activeDisplayID() ?? CGMainDisplayID()
        let displayBounds = CGDisplayBounds(display)
        let strip = self.strip(band).offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        guard let image = displayCapture(display, strip)?.takeRetainedValue() else { return nil }
        return reading(from: image)
    }

    private static func strip(_ band: Band) -> CGRect {
        CGRect(x: band.bounds.minX + band.bounds.width * 0.2,
               y: band.bounds.midY - 8,
               width: band.bounds.width * 0.6,
               height: 16)
    }

    // Captures the band's own pixels, not the screen under it, so the
    // verdict reflects that window's backing store.
    private static func measure(_ band: Band) -> Reading? {
        guard let image = windowCapture(strip(band), 8, UInt32(band.id), 0)?.takeRetainedValue()
        else { return nil }
        return reading(from: image)
    }

    private static func reading(from image: CGImage) -> Reading? {
        guard let data = image.dataProvider?.data as Data? else { return nil }
        var values: [Double] = []
        values.reserveCapacity(image.width * image.height)
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let b = Double(data[offset]), g = Double(data[offset + 1]), r = Double(data[offset + 2])
                values.append((r + g + b) / 3)
            }
        }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return Reading(mean: mean, deviation: variance.squareRoot())
    }
}
