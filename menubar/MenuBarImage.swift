// pulse-menubar: renders the menu bar item as one image, battery-style:
// the text on the left, a ring that fills clockwise on the right.
//
//   pulse-menubar <percent> <text> <text-hex> <arc-hex> <track-hex>
//
// Prints "<width> <height> <base64 png>" in points; the PNG is 2x for Retina.
// Build: ./build.sh

import Cocoa

func color(_ hex: String) -> NSColor {
    var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    let v = UInt32(h, radix: 16) ?? 0x00ff00
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

let a = CommandLine.arguments
guard a.count >= 6, let pct = Double(a[1]) else {
    FileHandle.standardError.write("usage: pulse-menubar <percent> <text> <text-hex> <arc-hex> <track-hex>\n".data(using: .utf8)!)
    exit(64)
}
let text = a[2], textColor = color(a[3]), arcColor = color(a[4]), trackColor = color(a[5])

let font = NSFont.menuBarFont(ofSize: 0)
let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor])
let textSize = label.size()
let ring: CGFloat = 15, stroke: CGFloat = 3.5, gap: CGFloat = 5, height: CGFloat = 18
// SwiftBar shows this image left of an (empty) title, and AppKit keeps the image-to-title
// gap and the title inset on the right. A matching transparent pad on the left keeps the
// item visually centred in its highlight.
let lead: CGFloat = 6
let width = lead + ceil(textSize.width) + (text.isEmpty ? 0 : gap) + ring
let scale: CGFloat = 2

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
ctx.cgContext.scaleBy(x: scale, y: scale)
ctx.shouldAntialias = true

label.draw(at: NSPoint(x: lead, y: (height - textSize.height) / 2))

let center = NSPoint(x: width - ring / 2, y: height / 2)
let radius = ring / 2 - stroke / 2
let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
track.lineWidth = stroke
trackColor.setStroke()
track.stroke()
if pct > 0 {
    let arc = NSBezierPath()
    arc.lineWidth = stroke
    arc.lineCapStyle = .round
    // AppKit angles: degrees, counter-clockwise, 0 at 3 o'clock. Start at 12, sweep clockwise.
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * min(pct, 100) / 100, clockwise: true)
    arcColor.setStroke()
    arc.stroke()
}
NSGraphicsContext.restoreGraphicsState()
rep.size = NSSize(width: width, height: height)     // points: writes the 2x DPI into the PNG

let png = rep.representation(using: .png, properties: [:])!
print("\(Int(width)) \(Int(height)) \(png.base64EncodedString())")
