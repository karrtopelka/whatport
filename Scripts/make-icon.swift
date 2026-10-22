#!/usr/bin/env swift
// Renders the WhatPort app icon as PNGs into the asset catalog.
// Usage: swift Scripts/make-icon.swift <output appiconset dir>
import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/WhatPort/Resources/Assets.xcassets/AppIcon.appiconset"

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS icon grid: the squircle occupies ~82% of the canvas.
    let inset = size * 0.09
    let rect = canvas.insetBy(dx: inset, dy: inset)
    let radius = rect.width * 0.225
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Shadow
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 1).setFill()
    shape.fill()
    context.restoreGState()

    // Gradient background
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.70, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.36, blue: 0.92, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.55, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -70)

    // Subtle top highlight
    let highlight = NSGradient(starting: NSColor.white.withAlphaComponent(0.28), ending: NSColor.white.withAlphaComponent(0.0))!
    highlight.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: 90)

    // Glyph: a port "socket" — rounded square outline with a dot grid, plus a cable.
    let glyphSize = rect.width * 0.52
    let glyphRect = CGRect(x: rect.midX - glyphSize / 2, y: rect.midY - glyphSize / 2 + rect.height * 0.03, width: glyphSize, height: glyphSize)
    let line = max(1, size * 0.055)
    let outline = NSBezierPath(roundedRect: glyphRect, xRadius: glyphSize * 0.22, yRadius: glyphSize * 0.22)
    outline.lineWidth = line
    NSColor.white.withAlphaComponent(0.95).setStroke()
    outline.stroke()

    // Three "pins"
    let pinWidth = glyphSize * 0.12
    let pinHeight = glyphSize * 0.34
    let gap = glyphSize * 0.1
    let totalWidth = pinWidth * 3 + gap * 2
    var x = glyphRect.midX - totalWidth / 2
    let pinY = glyphRect.midY - pinHeight / 2
    for index in 0..<3 {
        let pinRect = CGRect(x: x, y: pinY, width: pinWidth, height: pinHeight)
        let pin = NSBezierPath(roundedRect: pinRect, xRadius: pinWidth / 2, yRadius: pinWidth / 2)
        (index == 1 ? NSColor(calibratedRed: 0.55, green: 1.0, blue: 0.75, alpha: 1) : NSColor.white).setFill()
        pin.fill()
        x += pinWidth + gap
    }

    // Cable going down out of the socket
    let cable = NSBezierPath()
    cable.move(to: CGPoint(x: glyphRect.midX, y: glyphRect.minY))
    cable.line(to: CGPoint(x: glyphRect.midX, y: rect.minY + rect.height * 0.12))
    cable.lineWidth = line
    cable.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.95).setStroke()
    cable.stroke()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { fatalError("bitmap") }
    // Re-render at exact pixel size to avoid Retina scaling surprises.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    bitmap.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    try! png.write(to: URL(fileURLWithPath: path))
}

try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
let master = render(size: 1024)
let sizes: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let filename = "icon_\(points)x\(points)@\(scale)x.png"
    writePNG(master, pixels: points * scale, to: "\(outputDirectory)/\(filename)")
    images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! data.write(to: URL(fileURLWithPath: "\(outputDirectory)/Contents.json"))
print("Wrote \(images.count) icons to \(outputDirectory)")
