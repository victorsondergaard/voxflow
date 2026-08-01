// Draws the VoxFlow app icon programmatically (no binary assets in the repo):
// a deep ocean-to-teal gradient rounded square with the signature waveform
// capsule. Run by CI: swift scripts/make-icon.swift AppIcon.iconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(pixels: Int) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("could not create bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(pixels)
    // macOS icon grid: content sits inside ~10% padding with a squircle-ish radius.
    let inset = side * 0.09
    let rect = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let background = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.03, green: 0.13, blue: 0.25, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.02, green: 0.47, blue: 0.55, alpha: 1.0)
    )!
    gradient.draw(in: background, angle: 90)

    // The capsule (same silhouette as the on-screen HUD).
    let capWidth = rect.width * 0.76
    let capHeight = rect.height * 0.30
    let capRect = NSRect(x: rect.midX - capWidth / 2, y: rect.midY - capHeight / 2,
                         width: capWidth, height: capHeight)
    NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
    NSBezierPath(roundedRect: capRect, xRadius: capHeight / 2, yRadius: capHeight / 2).fill()

    // Waveform bars in VoxFlow teal.
    let heights: [CGFloat] = [0.30, 0.52, 0.84, 0.62, 1.00, 0.62, 0.84, 0.52, 0.30]
    let innerWidth = capWidth * 0.76
    let barWidth = innerWidth / CGFloat(heights.count * 2 - 1)
    NSColor(calibratedRed: 0.36, green: 0.86, blue: 0.85, alpha: 1.0).setFill()
    for (index, factor) in heights.enumerated() {
        let barHeight = capHeight * 0.74 * factor
        let x = capRect.midX - innerWidth / 2 + CGFloat(index) * barWidth * 2
        let y = capRect.midY - barHeight / 2
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: barHeight),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = draw(pixels: size * scale)
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("could not encode \(name)")
        }
        try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
print("iconset written to \(outDir)")
