import AppKit
import ApplicationServices
import QuartzCore

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> UInt32

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

// Independent experiments for the purged fullscreen toolbar backing (#63).
// A recognized name returns true even when the operation is refused or skipped.
// Only a before/after pixel capture can establish whether the toolbar healed.
enum WedgeHeals {
    static let names: [String] = [
        "alpha-nudge", "level-nudge", "occlusion-cover", "resolution-nudge",
        "ax-owner-nudge", "top-edge-dwell", "dock-ramp", "dock-ramp-wide",
    ]

    static func describe(_ name: String) -> String {
        switch name {
        case "alpha-nudge":
            return "Briefly change the companion alpha, then restore its original value."
        case "level-nudge":
            return "Briefly change the companion window level, then restore its original value."
        case "occlusion-cover":
            return "Cover and uncover the fullscreen display with an opaque panel (brief black flash)."
        case "resolution-nudge":
            return "Change the companion backing resolution, then restore its original value."
        case "ax-owner-nudge":
            return "Nudge the owner's real window through Accessibility to request a group layout."
        case "top-edge-dwell":
            return "Dwell at the target display's top edge for 750 ms, then restore the cursor."
        case "dock-ramp":
            return "Ramp a dock swipe ~2pt and cancel, without committing a switch."
        case "dock-ramp-wide":
            return "Ramp a dock swipe ~40pt and cancel, without committing a switch."
        default:
            return "Unknown heal."
        }
    }

    @discardableResult
    static func apply(_ name: String,
                      companionWindowID: Int,
                      companionBounds: CGRect,
                      ownerPID: pid_t,
                      space: UInt64) -> Bool {
        guard names.contains(name) else { return false }
        guard let wid = UInt32(exactly: companionWindowID), wid != 0, ownerPID > 0,
              companionBounds.minX.isFinite, companionBounds.minY.isFinite,
              companionBounds.maxX.isFinite, companionBounds.maxY.isFinite,
              !companionBounds.isEmpty else {
            Log.write("wedge-heal: \(name) skipped: invalid target")
            return true
        }

        let work = {
            guard targetIsVisible(wid, ownerPID: ownerPID, space: space) else {
                Log.write("wedge-heal: \(name) skipped: target is no longer visible on the active Space")
                return
            }
            switch name {
            case "alpha-nudge": alphaNudge(wid)
            case "level-nudge": levelNudge(wid)
            case "occlusion-cover": occlusionCover(companionBounds)
            case "resolution-nudge": resolutionNudge(wid)
            case "ax-owner-nudge":
                axOwnerNudge(ownerPID, companionWindowID: wid, companionBounds: companionBounds, space: space)
            case "top-edge-dwell": topEdgeDwell(companionBounds, windowID: wid, ownerPID: ownerPID, space: space)
            // The only mechanism with prior evidence of healing the band.
            // It was dropped from the app because its frames collide with
            // the next navigation, but on macOS 27 it was never tested: it
            // went out without the payload and the Dock ignored it.
            case "dock-ramp": Spaces.postHealRamp(right: false, peakPoints: 2)
            case "dock-ramp-wide": Spaces.postHealRamp(right: false, peakPoints: 40)
            default: break
            }
        }

        // AX timeouts and the cursor dwell run off the main queue, including
        // their restores. A command-line caller can sleep after apply().
        // AppKit panel operations stay on the main thread and finish inline.
        if name == "occlusion-cover" {
            if Thread.isMainThread { work() }
            else { DispatchQueue.main.async(execute: work) }
        } else {
            worker.async(execute: work)
        }
        return true
    }

    private static let worker = DispatchQueue(label: "cyclist.wedge-heals", qos: .userInitiated)

    private typealias GetAlphaFn = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetAlphaFn = @convention(c) (UInt32, UInt32, Float) -> Int32
    private typealias GetLevelFn = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias SetLevelFn = @convention(c) (UInt32, UInt32, Int32) -> Int32
    private typealias GetResolutionFn = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<Double>) -> Int32
    private typealias SetResolutionFn = @convention(c) (UInt32, UInt32, Double) -> Int32

    private static func resolve<T>(_ name: String, as type: T.Type) -> T {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        return unsafeBitCast(dlsym(rtldDefault, name)!, to: type)
    }

    private static let SLSGetWindowAlpha = resolve("SLSGetWindowAlpha", as: GetAlphaFn.self)
    private static let SLSSetWindowAlpha = resolve("SLSSetWindowAlpha", as: SetAlphaFn.self)
    private static let SLSGetWindowLevel = resolve("SLSGetWindowLevel", as: GetLevelFn.self)
    private static let SLSSetWindowLevel = resolve("SLSSetWindowLevel", as: SetLevelFn.self)
    private static let SLSGetWindowResolution = resolve("SLSGetWindowResolution", as: GetResolutionFn.self)
    private static let SLSSetWindowResolution = resolve("SLSSetWindowResolution", as: SetResolutionFn.self)

    // Alpha changes invalidate compositor blending for this window. A distinct
    // frame at a different alpha can make WindowServer revisit its backing.
    // Long shot: recompositing cannot supply pixels that the owner never drew,
    // and WindowServer can reject changes from a different process.
    private static func alphaNudge(_ wid: UInt32) {
        let cid = CGSMainConnectionID()
        var original = Float.nan
        guard report(SLSGetWindowAlpha(cid, wid, &original), "alpha-nudge read"),
              original.isFinite, (0...1).contains(original) else { return }
        let changed: Float = original >= 0.02 ? original - 0.01 : original + 0.01
        defer { report(SLSSetWindowAlpha(cid, wid, original), "alpha-nudge restore") }
        guard report(SLSSetWindowAlpha(cid, wid, changed), "alpha-nudge set") else { return }
        Thread.sleep(forTimeInterval: 0.05)
    }

    // A level change rebuilds stacking and visible regions around the companion.
    // Restore the queried level instead of assuming that fullscreen chrome uses
    // level zero. Long shot: the backing can stay empty, and foreign-window
    // setters can fail. This also briefly changes stacking within the group.
    private static func levelNudge(_ wid: UInt32) {
        let cid = CGSMainConnectionID()
        var original: Int32 = 0
        guard report(SLSGetWindowLevel(cid, wid, &original), "level-nudge read") else { return }
        let changed = original == Int32.max ? original - 1 : original + 1
        defer { report(SLSSetWindowLevel(cid, wid, original), "level-nudge restore") }
        guard report(SLSSetWindowLevel(cid, wid, changed), "level-nudge set") else { return }
        Thread.sleep(forTimeInterval: 0.05)
    }

    // A fully opaque cover changes the owner's windows from visible to occluded
    // and back, so AppKit can resume drawing when it receives the visibility
    // notification. Cover the whole display: a strip leaves the parent visible.
    // This deliberately flashes black for 150 ms and never activates the panel.
    // AppKit can still coalesce notifications or reuse the empty backing, so a
    // visibility change does not guarantee a redraw.
    private static func occlusionCover(_ bounds: CGRect) {
        guard let display = displayBounds(for: bounds) else { return }
        _ = NSApplication.shared
        // Quartz uses a top-left origin, AppKit a bottom-left origin relative
        // to the primary display. This conversion also covers offset displays.
        let frame = CGRect(x: display.minX, y: CGDisplayBounds(CGMainDisplayID()).maxY - display.maxY,
                           width: display.width, height: display.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = .screenSaver
        defer {
            panel.orderOut(nil)
            panel.close()
            CATransaction.flush()
        }
        panel.orderFrontRegardless()
        panel.display()
        CATransaction.flush()
        Thread.sleep(forTimeInterval: 0.15)
        Log.write("wedge-heal: occlusion-cover completed")
    }

    // A backing-resolution change can invalidate raster storage and provoke a
    // backing-properties update in the owner. Preserve the queried value, which
    // can be zero for automatic resolution. Long shot: SkyLight can restrict
    // this operation to locally owned windows or resample without an app redraw.
    private static func resolutionNudge(_ wid: UInt32) {
        let cid = CGSMainConnectionID()
        var original = Double.nan
        guard report(SLSGetWindowResolution(cid, wid, &original), "resolution-nudge read"),
              original.isFinite, original == 0 || (1...16).contains(original) else { return }
        let changed = original == 1 ? 2.0 : 1.0
        defer { report(SLSSetWindowResolution(cid, wid, original), "resolution-nudge restore") }
        guard report(SLSSetWindowResolution(cid, wid, changed), "resolution-nudge set") else { return }
        Thread.sleep(forTimeInterval: 0.05)
    }

    // Request geometry changes through the owner's real AX window, which lets
    // AppKit lay out its associated fullscreen chrome. The companion has no AX
    // element, so restrict selection to real siblings on the supplied Space.
    // Long shot: fullscreen windows can refuse geometry changes, and a parent
    // layout does not necessarily invalidate the companion's separate backing.
    private static func axOwnerNudge(_ pid: pid_t, companionWindowID: UInt32,
                                     companionBounds: CGRect, space: UInt64) {
        guard AXIsProcessTrusted() else {
            Log.write("wedge-heal: ax-owner-nudge skipped: Accessibility is not granted")
            return
        }
        let realIDs = Spaces.realWindows(among: Spaces.windowIDs(inSpace: space))
        guard let display = displayBounds(for: companionBounds),
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return }
        // Prefer the fullscreen content window over owner dialogs or sheets.
        let candidates = windows.compactMap { info -> (id: Int, area: CGFloat)? in
            guard let id = info[kCGWindowNumber as String] as? Int, id != Int(companionWindowID),
                  realIDs.contains(id), (info[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  let rect = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return nil }
            let visible = bounds.intersection(display)
            guard visible.width >= display.width - 2, visible.height > display.height * 0.5 else { return nil }
            return (id, visible.width * visible.height)
        }
        guard let contentID = candidates.max(by: { $0.area < $1.area })?.id else {
            Log.write("wedge-heal: ax-owner-nudge found no fullscreen content window")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let items = value as? [AnyObject] else {
            Log.write("wedge-heal: ax-owner-nudge could not read owner windows")
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        for item in items.prefix(32) where CFGetTypeID(item) == AXUIElementGetTypeID() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            let window = item as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.04)
            var wid: UInt32 = 0
            guard _AXUIElementGetWindow(window, &wid) == .success,
                  Int(wid) == contentID else { continue }
            guard targetIsVisible(companionWindowID, ownerPID: pid, space: space) else { return }
            // A size change asks for layout. Fall back to the position path
            // when the owner refuses resizing, as some fullscreen apps do.
            if pulseAXGeometry(window, attribute: kAXSizeAttribute, type: .cgSize)
                || pulseAXGeometry(window, attribute: kAXPositionAttribute, type: .cgPoint) { return }
        }
        Log.write("wedge-heal: ax-owner-nudge found no sibling that accepted a geometry change")
    }

    private static func pulseAXGeometry(_ window: AXUIElement, attribute: String, type: AXValueType) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, attribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        let original = value as! AXValue
        guard AXValueGetType(original) == type else { return false }

        let changed: AXValue?
        if type == .cgSize {
            var size = CGSize.zero
            guard AXValueGetValue(original, .cgSize, &size),
                  size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return false }
            size.width -= 1
            changed = AXValueCreate(.cgSize, &size)
        } else {
            var point = CGPoint.zero
            guard AXValueGetValue(original, .cgPoint, &point), point.x.isFinite, point.y.isFinite else { return false }
            point.x += 1
            changed = AXValueCreate(.cgPoint, &point)
        }
        guard let changed else { return false }
        // Even a timed-out setter can reach the app, so attempt restoration
        // after every write, including writes that report an AX error.
        defer {
            report(AXUIElementSetAttributeValue(window, attribute as CFString, original).rawValue,
                   "ax-owner-nudge \(attribute) restore")
        }
        guard report(AXUIElementSetAttributeValue(window, attribute as CFString, changed).rawValue,
                     "ax-owner-nudge \(attribute) set") else { return false }
        Thread.sleep(forTimeInterval: 0.04)
        var observed: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &observed) == .success,
              let observed else { return false }
        return !CFEqual(original, observed)
    }

    // Mouse tracking at the actual display edge enters AppKit's fullscreen
    // toolbar reveal path, which can lay out and draw the companion. Warping
    // alone does not send tracking events, so post only ordinary mouse moves.
    // This depends on toolbar auto-hide behavior and is not a proven heal.
    // The worker owns the saved cursor until it restores it, even on early exit.
    private static func topEdgeDwell(_ bounds: CGRect, windowID: UInt32, ownerPID: pid_t, space: UInt64) {
        guard let display = displayBounds(for: bounds), let original = CGEvent(source: nil)?.location,
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right),
              let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let edge = CGPoint(x: display.midX, y: display.minY)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: edge, mouseButton: .left),
              let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                    mouseCursorPosition: original, mouseButton: .left) else { return }
        defer {
            restore.post(tap: .cghidEventTap)
            report(CGWarpMouseCursorPosition(original).rawValue, "top-edge-dwell cursor restore")
        }
        guard report(CGWarpMouseCursorPosition(edge).rawValue, "top-edge-dwell cursor move") else { return }
        move.post(tap: .cghidEventTap)
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.05)
            if !targetIsVisible(windowID, ownerPID: ownerPID, space: space) { break }
        }
    }

    private static func targetIsVisible(_ wid: UInt32, ownerPID: pid_t, space: UInt64) -> Bool {
        guard Spaces.activeDisplayInfo()?.current == space,
              Spaces.windowIDs(inSpace: space).contains(Int(wid)),
              let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == Int(wid) }) else { return false }
        return (info[kCGWindowOwnerPID as String] as? Int) == Int(ownerPID)
            && (info[kCGWindowIsOnscreen as String] as? Bool) == true
    }

    private static func displayBounds(for bounds: CGRect) -> CGRect? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let error = displays.withUnsafeMutableBufferPointer {
            CGGetDisplaysWithRect(bounds, UInt32($0.count), $0.baseAddress, &count)
        }
        guard error == .success else { return nil }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }.max {
            let a = $0.intersection(bounds), b = $1.intersection(bounds)
            return a.width * a.height < b.width * b.height
        }
    }

    @discardableResult
    private static func report(_ status: Int32, _ operation: String) -> Bool {
        Log.write("wedge-heal: \(operation) status=\(status)")
        return status == 0
    }
}
