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

let top = NSColor(calibratedRed: 0.40, green: 0.36, blue: 0.90, alpha: 1)  // indigo
let bottom = NSColor(calibratedRed: 0.16, green: 0.46, blue: 0.96, alpha: 1) // blue
NSGradient(starting: top, ending: bottom)!.draw(in: rect, angle: -60)

// White sync-arrows glyph, centered.
let conf = NSImage.SymbolConfiguration(pointSize: 480, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                        accessibilityDescription: nil)?.withSymbolConfiguration(conf) {
    let s = symbol.size
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    symbol.draw(at: .zero, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
    tinted.draw(at: origin, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
