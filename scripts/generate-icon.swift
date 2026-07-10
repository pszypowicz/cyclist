#!/usr/bin/env swift
import AppKit

// Renders the Cyclist app icon: a white SF Symbol on a gradient squircle,
// exported at every size an .icns needs.

func usage() {
    print("""
    Generate the Cyclist app icon (.icns) from an SF Symbol.

    Usage: swift scripts/generate-icon.swift [--output <path>] [--glyph <sf-symbol-name>] [--master-png <path>]

    Flags:
      --output      Path of the .icns to write (default: Resources/AppIcon.icns)
      --glyph       SF Symbol to draw (default: arrow.triangle.2.circlepath)
      --master-png  Also save the 1024x1024 master PNG at this path (optional)
      -h, --help    Show this help.

    Example:
      swift scripts/generate-icon.swift --glyph bicycle
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var output = "Resources/AppIcon.icns"
var glyph = "arrow.triangle.2.circlepath"
var masterPNG: String?

var args = Array(CommandLine.arguments.dropFirst())
func takeValue(for flag: String) -> String {
    guard !args.isEmpty else { fail("Missing value for \(flag)") }
    return args.removeFirst()
}
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--output": output = takeValue(for: arg)
    case "--glyph": glyph = takeValue(for: arg)
    case "--master-png": masterPNG = takeValue(for: arg)
    case "-h", "--help": usage(); exit(0)
    default: fail("Unknown argument: \(arg)\nRun with --help for usage.")
    }
}

guard let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 480, weight: .medium)) else {
    fail("Unknown SF Symbol: \(glyph)")
}

let tintedSymbol = NSImage(size: symbol.size, flipped: false) { rect in
    symbol.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceIn)
    return true
}

let canvas: CGFloat = 1024
let master = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }

    // Apple's icon grid: an 824pt squircle centered on a 1024pt canvas,
    // with a soft shadow baked into the artwork.
    let box = rect.insetBy(dx: 100, dy: 100)
    let squircle = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -10),
        blur: 22,
        color: NSColor.black.withAlphaComponent(0.3).cgColor
    )
    NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.75, alpha: 1).setFill()
    squircle.fill()
    context.restoreGState()

    NSGradient(
        starting: NSColor(calibratedRed: 0.35, green: 0.58, blue: 0.95, alpha: 1),
        ending: NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.68, alpha: 1)
    )?.draw(in: squircle, angle: -90)

    let maxGlyph = box.width * 0.60
    let aspect = tintedSymbol.size.width / tintedSymbol.size.height
    var glyphWidth = maxGlyph
    var glyphHeight = glyphWidth / aspect
    if glyphHeight > maxGlyph {
        glyphHeight = maxGlyph
        glyphWidth = glyphHeight * aspect
    }
    tintedSymbol.draw(in: NSRect(
        x: rect.midX - glyphWidth / 2,
        y: rect.midY - glyphHeight / 2,
        width: glyphWidth,
        height: glyphHeight
    ))
    return true
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("Could not create bitmap for \(pixels)px") }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("Could not encode PNG for \(pixels)px")
    }
    do { try data.write(to: url) } catch { fail("Could not write \(url.path): \(error)") }
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory
    .appendingPathComponent("CyclistIcon-\(ProcessInfo.processInfo.globallyUniqueString)")
    .appendingPathComponent("AppIcon.iconset")
do { try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true) }
catch { fail("Could not create temp iconset: \(error)") }

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let suffix = scale == 2 ? "@2x" : ""
    writePNG(master, pixels: points * scale,
             to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}

if let masterPNG {
    writePNG(master, pixels: 1024, to: URL(fileURLWithPath: masterPNG))
}

let outputURL = URL(fileURLWithPath: output)
try? fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
do {
    try iconutil.run()
    iconutil.waitUntilExit()
} catch { fail("Could not run iconutil: \(error)") }
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

try? fileManager.removeItem(at: iconset.deletingLastPathComponent())
print("Wrote \(output) (glyph: \(glyph))")
