import AppKit

// Generates a 1024×1024 PNG app icon for Glance: a violet gradient squircle
// with a white "sparkles" glyph. build.sh turns this into AppIcon.icns.
// Usage: mkicon <output.png>
let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let corner = size * 0.2237   // Apple-ish rounded-rect proportion
NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()

// Gradient backdrop (indigo → violet).
let top = NSColor(srgbRed: 0.48, green: 0.38, blue: 0.99, alpha: 1)
let bottom = NSColor(srgbRed: 0.29, green: 0.22, blue: 0.76, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: rect, angle: -90)

// Soft top sheen.
NSColor(white: 1, alpha: 0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: -size * 0.2, y: size * 0.46, width: size * 1.4, height: size * 0.9)).fill()

// White "sparkles" glyph, centered.
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
if let base = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let gs = base.size
    let tinted = NSImage(size: gs)
    tinted.lockFocus()
    NSColor.white.set()
    let gr = NSRect(origin: .zero, size: gs)
    base.draw(in: gr)
    gr.fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: NSRect(x: (size - gs.width) / 2, y: (size - gs.height) / 2,
                           width: gs.width, height: gs.height),
                from: .zero, operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render icon\n".utf8))
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
