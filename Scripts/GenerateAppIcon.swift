#!/usr/bin/env swift
import AppKit
import Foundation

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func renderIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let margin = s * 0.08
    let corner = s * 0.22
    let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(srgbRed: 0.16, green: 0.14, blue: 0.12, alpha: 1),
        CGColor(srgbRed: 0.08, green: 0.075, blue: 0.07, alpha: 1),
        CGColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.5, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    ctx.setStrokeColor(CGColor(srgbRed: 0.86, green: 0.62, blue: 0.28, alpha: 0.45))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.addPath(path)
    ctx.strokePath()

    drawSheets(in: ctx, size: s, bounds: rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.18))
    return ctx.makeImage()
}

func drawSheets(in ctx: CGContext, size s: CGFloat, bounds: CGRect) {
    let sheetW = bounds.width * 0.78
    let sheetH = bounds.height * 0.62
    for index in 0..<3 {
        let step = CGFloat(index)
        let rect = CGRect(
            x: bounds.midX - sheetW / 2 + (step - 1) * s * 0.035,
            y: bounds.midY - sheetH / 2 + (1 - step) * s * 0.045,
            width: sheetW,
            height: sheetH
        )
        let radius = max(2, s * 0.04)
        let sheet = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let alpha = 0.28 + 0.24 * step
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.09, blue: 0.08, alpha: alpha))
        ctx.addPath(sheet)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: 0.90, green: 0.70, blue: 0.36, alpha: 0.35 + 0.25 * step))
        ctx.setLineWidth(max(1, s * 0.012))
        ctx.addPath(sheet)
        ctx.strokePath()
    }

    let front = CGRect(
        x: bounds.midX - sheetW / 2 + s * 0.035,
        y: bounds.midY - sheetH / 2 - s * 0.045,
        width: sheetW,
        height: sheetH
    )
    let clockR = min(front.width, front.height) * 0.28
    let center = CGPoint(x: front.midX, y: front.midY + clockR * 0.05)
    let dial = CGRect(x: center.x - clockR, y: center.y - clockR, width: clockR * 2, height: clockR * 2)
    ctx.setStrokeColor(CGColor(srgbRed: 0.95, green: 0.76, blue: 0.42, alpha: 1))
    ctx.setLineWidth(max(1.2, s * 0.018))
    ctx.strokeEllipse(in: dial)
    ctx.setLineCap(.round)
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x, y: center.y + clockR * 0.62))
    ctx.move(to: center)
    ctx.addLine(to: CGPoint(x: center.x + clockR * 0.42, y: center.y - clockR * 0.08))
    ctx.strokePath()
    if s >= 32 {
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.76, blue: 0.42, alpha: 1))
        let dot = max(1.5, s * 0.012)
        ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
    }
}

func pngData(_ image: CGImage) -> Data? {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for item in sizes {
    guard let image = renderIcon(size: item.px), let png = pngData(image) else {
        fputs("Failed to render \(item.name)\n", stderr)
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(item.name).png"))
}

if let master = renderIcon(size: 1024), let png = pngData(master) {
    try png.write(to: assets.appendingPathComponent("AppIcon-1024.png"))
}

let icns = assets.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("Created \(icns.path)")
