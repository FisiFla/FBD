// Regenerates Sources/FBD/Resources/FBD.icns (macOS-style squircle icon:
// gradient + display glyph). Run from the repo root:
//   swift Sources/FBD/Resources/make_icon.swift
// Requires iconutil (present on macOS).
import AppKit
import CoreGraphics

let iconSize: CGFloat = 1024
let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(iconSize),
    pixelsHigh: Int(iconSize),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

let ctx = NSGraphicsContext(bitmapImageRep: canvas)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

// Background: macOS-style squircle (inset + rounded rect).
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: iconSize - 2 * inset, height: iconSize - 2 * inset)
let radius: CGFloat = 185
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
cg.addPath(path)
cg.clip()

let colors = [
    NSColor(calibratedRed: 0.35, green: 0.34, blue: 0.84, alpha: 1).cgColor, // indigo
    NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.55, alpha: 1).cgColor, // deep blue
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
cg.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

// Subtle top highlight.
cg.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
cg.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))

// Glyph: display outline (white) + sun rays above.
cg.setStrokeColor(NSColor.white.cgColor)
cg.setLineWidth(56)
cg.setLineCap(.round)
cg.setLineJoin(.round)

let monitor = CGRect(x: rect.midX - 280, y: rect.midY - 190, width: 560, height: 360)
let monitorPath = CGPath(roundedRect: monitor, cornerWidth: 48, cornerHeight: 48, transform: nil)
cg.addPath(monitorPath)
cg.strokePath()

// Stand.
cg.move(to: CGPoint(x: rect.midX - 70, y: monitor.minY))
cg.addLine(to: CGPoint(x: rect.midX + 70, y: monitor.minY))
cg.strokePath()
cg.setLineWidth(40)
cg.move(to: CGPoint(x: rect.midX, y: monitor.minY))
cg.addLine(to: CGPoint(x: rect.midX, y: monitor.minY - 110))
cg.strokePath()

// Brightness rays above the display.
let sunCenter = CGPoint(x: rect.midX, y: monitor.maxY + 130)
let sunRadius: CGFloat = 90
cg.setLineWidth(36)
for angle in stride(from: 0.0, to: 360.0, by: 45.0) {
    let rad = angle * .pi / 180
    let inner = CGPoint(x: sunCenter.x + cos(rad) * sunRadius, y: sunCenter.y + sin(rad) * sunRadius)
    let outer = CGPoint(x: sunCenter.x + cos(rad) * (sunRadius + 85), y: sunCenter.y + sin(rad) * (sunRadius + 85))
    cg.move(to: inner)
    cg.addLine(to: outer)
    cg.strokePath()
}
cg.setFillColor(NSColor.white.cgColor)
cg.fillEllipse(in: CGRect(x: sunCenter.x - 55, y: sunCenter.y - 55, width: 110, height: 110))

NSGraphicsContext.current = nil

// Write the iconset.
let iconset = URL(fileURLWithPath: "/tmp/FBD.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in sizes {
    guard let scaled = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { continue }
    NSGraphicsContext.saveGraphicsState()
    let sctx = NSGraphicsContext(bitmapImageRep: scaled)!
    NSGraphicsContext.current = sctx
    canvas.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.current = nil
    NSGraphicsContext.restoreGraphicsState()
    try scaled.representation(using: .png, properties: [:])?.write(to: iconset.appendingPathComponent(name))
}
print("iconset written to \(iconset.path)")
