// Renders the Motas app icon (1024×1024 PNG) with Core Graphics.
//   swift scripts/dev/make-icon.swift dist/AppIcon-1024.png
//
// Concept: a quota pool — four capsule bars in the provider colors used across
// the app (Codex, Claude, Antigravity, Gemini), each filled to a different
// level, on a graphite squircle laid out on Apple's macOS icon grid.
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "dist/AppIcon-1024.png"
let size: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Apple grid: 824pt body centered, ~185pt continuous corners, soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(rgb(0x1B1E24))
ctx.fillPath()
ctx.restoreGState()

// Body gradient + top highlight.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2C313A), rgb(0x16191E)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 120), options: [])
ctx.restoreGState()

// Inner stroke for definition on dark docks.
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
ctx.setLineWidth(3)
ctx.strokePath()

// Four bars, top to bottom: fill levels tell a "pool" story (one running low).
let bars: [(color: UInt32, fill: CGFloat)] = [
    (0x49A3B0, 0.86),  // Codex
    (0xCC7C5E, 0.58),  // Claude
    (0x60BA7E, 1.00),  // Antigravity
    (0xAB87EA, 0.30),  // Gemini
]
let barHeight: CGFloat = 84, gap: CGFloat = 44
let barWidth: CGFloat = 560
let x0 = body.midX - barWidth / 2
let totalHeight = CGFloat(bars.count) * barHeight + CGFloat(bars.count - 1) * gap
var y = body.midY + totalHeight / 2 - barHeight
for bar in bars {
    let track = CGRect(x: x0, y: y, width: barWidth, height: barHeight)
    ctx.addPath(CGPath(roundedRect: track, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF, 0.10))
    ctx.fillPath()

    let fill = CGRect(x: x0, y: y, width: max(barHeight, barWidth * bar.fill), height: barHeight)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: fill, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
    ctx.clip()
    let grad = CGGradient(colorsSpace: space, colors: [rgb(bar.color), rgb(bar.color, 0.82)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: fill.maxY), end: CGPoint(x: 0, y: fill.minY), options: [])
    ctx.restoreGState()
    y -= barHeight + gap
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
