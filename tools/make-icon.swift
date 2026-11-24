// Draws the app icon. Run: swift tools/make-icon.swift  (writes Resources/AppIcon.icns)
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Background: macOS icon grid tile (824 pt inside a 1024 canvas).
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.25).cgColor)
    color(0xF2F2F5).setFill()
    tile.fill()
    ctx.restoreGState()
    NSGradient(starting: color(0xFAFAFC), ending: color(0xE4E4E9))!.draw(in: tile, angle: -90)

    // Cable: runs from the bottom edge of the tile up into the iPad's port.
    color(0x8E8E93).setFill()
    NSBezierPath(roundedRect: NSRect(x: 496, y: 100, width: 32, height: 180), xRadius: 16, yRadius: 16).fill()
    color(0xC7C7CC).setFill()
    NSBezierPath(roundedRect: NSRect(x: 478, y: 262, width: 68, height: 70), xRadius: 14, yRadius: 14).fill()

    // iPad, landscape.
    let body = NSRect(x: 192, y: 318, width: 640, height: 452)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.3).cgColor)
    color(0x1C1C1E).setFill()
    NSBezierPath(roundedRect: body, xRadius: 52, yRadius: 52).fill()
    ctx.restoreGState()

    let screen = body.insetBy(dx: 26, dy: 26)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 28, yRadius: 28)
    NSGradient(starting: color(0x2D6BE0), ending: color(0x58A6F5))!.draw(in: screenPath, angle: 60)

    // A Mac-style menu bar and window on the iPad screen: "this is a second display".
    ctx.saveGState()
    screenPath.addClip()
    color(0xFFFFFF, 0.85).setFill()
    NSRect(x: screen.minX, y: screen.maxY - 30, width: screen.width, height: 30).fill()
    let window = NSRect(x: screen.minX + 90, y: screen.minY + 60, width: screen.width - 180, height: screen.height - 150)
    color(0xFFFFFF, 0.95).setFill()
    NSBezierPath(roundedRect: window, xRadius: 14, yRadius: 14).fill()
    color(0xE5E5EA).setFill()
    NSBezierPath(roundedRect: NSRect(x: window.minX, y: window.maxY - 34, width: window.width, height: 34),
                 xRadius: 14, yRadius: 14).fill()
    for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        color(UInt32(hex)).setFill()
        NSBezierPath(ovalIn: NSRect(x: window.minX + 18 + CGFloat(i) * 22, y: window.maxY - 24, width: 14, height: 14)).fill()
    }
    ctx.restoreGState()

    // Front camera on the long top edge.
    color(0x3A3A3C).setFill()
    NSBezierPath(ovalIn: NSRect(x: body.midX - 6, y: body.maxY - 17, width: 12, height: 12)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
try drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
