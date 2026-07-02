import AppKit

// Renders the TandemClip app icon (white sync-arrows glyph on an indigo->blue
// rounded-rect) to a 1024x1024 PNG. Usage: swift render-icon.swift <out.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Rounded-rect background (macOS squircle-ish proportions).
let inset: CGFloat = 90
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius = rect.width * 0.2237
let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
bg.addClip()

// KeepFloat brand gradient, lightened: near-white paper → cream → clay →
// terracotta. Lots of white up top, brand colour anchoring the lower corner.
let paper      = NSColor(srgbRed: 0.980, green: 0.965, blue: 0.945, alpha: 1) // #faf6f1
let cream      = NSColor(srgbRed: 0.902, green: 0.839, blue: 0.773, alpha: 1) // #e6d6c5 (brand-100)
let clay       = NSColor(srgbRed: 0.784, green: 0.475, blue: 0.310, alpha: 1) // #c8794f
let terracotta = NSColor(srgbRed: 0.698, green: 0.357, blue: 0.235, alpha: 1) // #b25b3c
NSGradient(colorsAndLocations: (paper, 0.0), (cream, 0.32), (clay, 0.70), (terracotta, 1.0))!
    .draw(in: rect, angle: -45)

// Soft top-left white highlight so the surface reads glossy/light, not flat.
if let glow = NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 0.55),
                         ending: NSColor(calibratedWhite: 1, alpha: 0)) {
    glow.draw(in: rect, relativeCenterPosition: NSPoint(x: -0.45, y: 0.45))
}

// Sync-arrows glyph, centered, in brand terracotta (reads on the light field)
// with a soft shadow for depth.
let conf = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                        accessibilityDescription: nil)?.withSymbolConfiguration(conf) {
    let s = symbol.size
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
    terracotta.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.2, alpha: 0.22)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    tinted.draw(at: origin, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
