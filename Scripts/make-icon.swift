// Renders Resources/AppIcon.icns.  Usage: swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    // macOS icon grid: 824/1024 body with rounded corners.
    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(red: 0.36, green: 0.72, blue: 1, alpha: 1),
               ending: NSColor(red: 0.04, green: 0.42, blue: 0.95, alpha: 1))!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 0.1, green: 0.5, blue: 0.97, alpha: 1), .white]))
    if let symbol = NSImage(systemSymbolName: "checkmark.message.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let r = NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2,
                       width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: r)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
print(out.path)
