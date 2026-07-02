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

// Match the website mark: solid accent square with a white sync-arrows glyph.
// A whisper of top-lighter gradient keeps it from looking flat at icon sizes.
let accent      = NSColor(srgbRed: 224/255, green: 122/255, blue: 75/255, alpha: 1) // #e07a4b
let accentLight = NSColor(srgbRed: 236/255, green: 138/255, blue: 92/255, alpha: 1) // subtle highlight
NSGradient(starting: accentLight, ending: accent)!.draw(in: rect, angle: -90)

// White sync-arrows glyph, centered, with a soft shadow for a little depth.
let conf = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
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
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.35, alpha: 0.18)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -6)
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
