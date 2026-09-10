// Abstract mark proposal: the "half-orb" (circle, right half hidden = peek).
// 3 app-icon treatments + menu-bar-size previews, one sheet.
// Output: Design/proposals/abstract-orb.png
import AppKit

let S: CGFloat = 1024
let inset: CGFloat = 64
let iconRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)

func bgSquircle(_ ctx: CGContext) {
    let squircle = NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208)
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.34, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1),
    ])!.draw(in: squircle, angle: -55)
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.72, alpha: 0.45).cgColor,
                                NSColor(white: 0, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: 300, y: 760), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 760), endRadius: 620, options: [])
}

// The mark: circle with left half filled, right half "hidden". Filled-half
// color comes from caller; optionally stroked ring around the whole circle.
func halfOrb(center: CGPoint, r: CGFloat, fill: NSColor, ring: NSColor?, ringWidth: CGFloat = 0) -> NSImage {
    let img = NSImage(size: NSSize(width: r * 2 + 40, height: r * 2 + 40))
    img.lockFocus()
    let c = CGPoint(x: r + 20, y: r + 20)
    let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
    if let ring {
        ring.setStroke()
        let p = NSBezierPath(ovalIn: rect)
        p.lineWidth = ringWidth
        p.stroke()
    }
    fill.setFill()
    // left half
    NSBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: r, height: r * 2)).addClip()
    NSBezierPath(ovalIn: rect).fill()
    img.unlockFocus()
    return img
}

let cyan = NSColor(calibratedRed: 0.35, green: 0.75, blue: 1.0, alpha: 1)

// A: flat white half-orb, no ring
func variantA() -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    bgSquircle(ctx)
    halfOrb(center: .zero, r: 300, fill: NSColor(white: 1, alpha: 0.96), ring: nil)
        .draw(at: NSPoint(x: S / 2 - 320, y: S / 2 - 320), from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState(); img.unlockFocus()
    return img
}

// B: gradient cyan half-orb, no ring (brand pop)
func variantB() -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    bgSquircle(ctx)
    let r: CGFloat = 300
    let rect = CGRect(x: S / 2 - r, y: S / 2 - r, width: r * 2, height: r * 2)
    ctx.saveGState()
    NSBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: r, height: r * 2)).addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.55, green: 0.90, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
    ])!.draw(in: NSBezierPath(ovalIn: rect), angle: -90)
    ctx.restoreGState()
    ctx.restoreGState(); img.unlockFocus()
    return img
}

// C: thin ring + gradient half (most "designed")
func variantC() -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    bgSquircle(ctx)
    let r: CGFloat = 300
    let rect = CGRect(x: S / 2 - r, y: S / 2 - r, width: r * 2, height: r * 2)
    // ring
    NSColor(white: 1, alpha: 0.9).setStroke()
    let ring = NSBezierPath(ovalIn: rect)
    ring.lineWidth = 26
    ring.stroke()
    // gradient half
    ctx.saveGState()
    NSBezierPath(rect: CGRect(x: rect.minX, y: rect.minY, width: r, height: r * 2)).addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.55, green: 0.90, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
    ])!.draw(in: NSBezierPath(ovalIn: rect), angle: -90)
    ctx.restoreGState()
    ctx.restoreGState(); img.unlockFocus()
    return img
}

// MARK: sheet
let gap: CGFloat = 32
let menuStripH: CGFloat = 160
let sheet = NSImage(size: NSSize(width: S * 3 + gap * 4, height: S + gap * 2 + 60 + menuStripH))
sheet.lockFocus()
NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: sheet.size)).fill()

let variants: [() -> NSImage] = [variantA, variantB, variantC]
let labels = ["A: white half", "B: gradient half", "C: ring + gradient"]
for (i, make) in variants.enumerated() {
    let icon = make()
    let x = gap + CGFloat(i) * (S + gap)
    icon.draw(in: CGRect(x: x, y: gap + 60 + menuStripH, width: S, height: S))
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .medium),
        .foregroundColor: NSColor.darkGray,
    ]
    labels[i].draw(at: NSPoint(x: x + 8, y: menuStripH + 24), withAttributes: attrs)
}

// menu-bar-size previews: dark strip (white glyph) + light strip (black glyph)
let stripY: CGFloat = 30
NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
NSBezierPath(rect: CGRect(x: 0, y: stripY, width: sheet.size.width / 2, height: 100)).fill()
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSBezierPath(rect: CGRect(x: sheet.size.width / 2, y: stripY, width: sheet.size.width / 2, height: 100)).fill()

func tintedMark(color: NSColor, ring: Bool) -> NSImage {
    halfOrb(center: .zero, r: 22, fill: color,
            ring: ring ? color : nil, ringWidth: 5)
}
// left strip (dark): white glyph, plain + ringed; right strip (light): black glyph
let menuMarks: [(NSImage, CGFloat, CGFloat)] = [
    (tintedMark(color: .white, ring: false), 180, 0),
    (tintedMark(color: .white, ring: true), 480, 0),
    (tintedMark(color: .black, ring: false), sheet.size.width / 2 + 180, 0),
    (tintedMark(color: .black, ring: true), sheet.size.width / 2 + 480, 0),
]
for (m, x, _) in menuMarks {
    m.draw(in: CGRect(x: x, y: stripY + 16, width: 68, height: 68))
}
sheet.unlockFocus()

let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Design/proposals/abstract-orb.png"))
print("wrote Design/proposals/abstract-orb.png")
