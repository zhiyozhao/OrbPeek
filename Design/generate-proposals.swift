// Generates icon design proposals into Design/proposals/ for review.
// Usage: swift Design/generate-proposals.swift
import AppKit

let outDir = "Design/proposals"
let S: CGFloat = 1024
let inset: CGFloat = 64
let iconRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)

func newCanvas() -> (NSImage, CGContext) {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    return (img, NSGraphicsContext.current!.cgContext)
}

func save(_ img: NSImage, _ name: String) {
    img.unlockFocus()
    let tiff = img.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    // normalize to exactly 1024x1024 px regardless of backing scale
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote \(name).png")
}

func squircleClip(_ ctx: CGContext) -> NSBezierPath {
    let p = NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208)
    ctx.saveGState()
    p.addClip()
    return p
}

func bgGradient(_ sq: NSBezierPath, _ top: NSColor, _ bottom: NSColor, angle: CGFloat = -55) {
    NSGradient(colors: [top, bottom])!.draw(in: sq, angle: angle)
}

func glow(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, color: NSColor) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
}

let dark1 = NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.34, alpha: 1)
let dark2 = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1)
let cyan1 = NSColor(calibratedRed: 0.55, green: 0.90, blue: 1.00, alpha: 1)
let cyan2 = NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)

// MARK: - A: peek-orb — luminous orb half-hidden behind an edge band
do {
    let (img, ctx) = newCanvas()
    let sq = squircleClip(ctx)
    bgGradient(sq, dark1, dark2)
    glow(ctx, at: CGPoint(x: 300, y: 760), radius: 620,
         color: NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.72, alpha: 0.5))
    // orb behind the band
    let orbCenter = CGPoint(x: 700, y: 512)
    let orbR: CGFloat = 210
    glow(ctx, at: orbCenter, radius: orbR * 2.2, color: cyan2.withAlphaComponent(0.55))
    let orbRect = CGRect(x: orbCenter.x - orbR, y: orbCenter.y - orbR, width: orbR * 2, height: orbR * 2)
    NSGradient(colors: [NSColor.white, cyan1, cyan2])!
        .draw(in: NSBezierPath(ovalIn: orbRect), relativeCenterPosition: NSPoint(x: -0.25, y: 0.3))
    // edge band (the "wall") covering the orb's right part
    let band = NSBezierPath(roundedRect: CGRect(x: 690, y: iconRect.minY - 10, width: 320, height: iconRect.height + 20),
                            xRadius: 28, yRadius: 28)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.23, green: 0.27, blue: 0.44, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.23, alpha: 1),
    ])!.draw(in: band, angle: 0)
    ctx.restoreGState()
    save(img, "app-A-peek-orb")
}

// MARK: - B: eclipse — bright circle mostly eclipsed, one crescent peeking
do {
    let (img, ctx) = newCanvas()
    let sq = squircleClip(ctx)
    bgGradient(sq, NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.30, alpha: 1), dark2)
    // bright disc
    let discR: CGFloat = 280
    let discRect = CGRect(x: 512 - discR, y: 512 - discR, width: discR * 2, height: discR * 2)
    glow(ctx, at: CGPoint(x: 512, y: 512), radius: discR * 1.9, color: cyan2.withAlphaComponent(0.35))
    NSGradient(colors: [NSColor.white, NSColor(calibratedRed: 0.75, green: 0.85, blue: 0.98, alpha: 1)])!
        .draw(in: NSBezierPath(ovalIn: discRect), relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
    // occluder (same tone as bg), offset right
    let occR: CGFloat = 262
    let occRect = CGRect(x: 512 + 210 - occR, y: 512 + 30 - occR, width: occR * 2, height: occR * 2)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.26, alpha: 1), dark2])!
        .draw(in: NSBezierPath(ovalIn: occRect), relativeCenterPosition: NSPoint(x: 0.25, y: -0.2))
    ctx.restoreGState()
    save(img, "app-B-eclipse")
}

// MARK: - C: flat logo — solid edge bar + solid orb, no glow (minimal)
do {
    let (img, ctx) = newCanvas()
    let sq = squircleClip(ctx)
    bgGradient(sq, NSColor(calibratedRed: 0.14, green: 0.17, blue: 0.31, alpha: 1),
               NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.17, alpha: 1), angle: -90)
    // solid orb, right half behind the bar
    let orbR: CGFloat = 190
    let orbRect = CGRect(x: 640 - orbR, y: 512 - orbR, width: orbR * 2, height: orbR * 2)
    NSGradient(colors: [cyan1, cyan2])!.draw(in: NSBezierPath(ovalIn: orbRect), angle: -90)
    // flat edge bar
    let bar = NSBezierPath(roundedRect: CGRect(x: 640, y: iconRect.minY + 150, width: 120, height: iconRect.height - 300),
                           xRadius: 34, yRadius: 34)
    NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.97, alpha: 1).setFill()
    bar.fill()
    ctx.restoreGState()
    save(img, "app-C-flat-orb-bar")
}

// MARK: - D: fence peek — orb peeking over a horizontal edge
do {
    let (img, ctx) = newCanvas()
    let sq = squircleClip(ctx)
    bgGradient(sq, dark1, dark2)
    glow(ctx, at: CGPoint(x: 300, y: 760), radius: 620,
         color: NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.72, alpha: 0.5))
    // orb peeking over the fence
    let orbCenter = CGPoint(x: 512, y: 560)
    let orbR: CGFloat = 230
    glow(ctx, at: orbCenter, radius: orbR * 2.2, color: cyan2.withAlphaComponent(0.5))
    let orbRect = CGRect(x: orbCenter.x - orbR, y: orbCenter.y - orbR, width: orbR * 2, height: orbR * 2)
    NSGradient(colors: [NSColor.white, cyan1, cyan2])!
        .draw(in: NSBezierPath(ovalIn: orbRect), relativeCenterPosition: NSPoint(x: -0.2, y: 0.35))
    // fence band across the lower middle
    let fence = NSBezierPath(roundedRect: CGRect(x: iconRect.minX - 10, y: iconRect.minY + 120, width: iconRect.width + 20, height: 330),
                             xRadius: 30, yRadius: 30)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.23, green: 0.27, blue: 0.44, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.23, alpha: 1),
    ])!.draw(in: fence, angle: 90)
    ctx.restoreGState()
    save(img, "app-D-fence-peek")
}

// MARK: - menu bar icons (template: black + alpha), 36px canvas = 18pt @2x
func menuCanvas() -> (NSImage, CGContext) {
    let img = NSImage(size: NSSize(width: 36, height: 36))
    img.lockFocus()
    return (img, NSGraphicsContext.current!.cgContext)
}
let black = NSColor.black

// M1: eclipse dot — filled circle with a crescent bitten out on the right
do {
    let (img, ctx) = menuCanvas()
    _ = ctx
    black.setFill()
    NSBezierPath(ovalIn: CGRect(x: 7, y: 7, width: 22, height: 22)).fill()
    // bite
    NSBezierPath(ovalIn: CGRect(x: 16, y: 9.5, width: 17, height: 17)).fill()
    img.unlockFocus()
    // erase the bite via destination-out
    let out = NSImage(size: img.size)
    out.lockFocus()
    img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
    NSBezierPath(ovalIn: CGRect(x: 19, y: 10, width: 16, height: 16)).fill()
    save(out, "menu-M1-eclipse-dot")
}

// M2: bar + half orb peeking from behind it
do {
    let (img, ctx) = menuCanvas()
    _ = ctx
    black.setFill()
    NSBezierPath(ovalIn: CGRect(x: 6, y: 9, width: 18, height: 18)).fill()
    img.unlockFocus()
    let out = NSImage(size: img.size)
    out.lockFocus()
    img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
    NSBezierPath(ovalIn: CGRect(x: 15, y: 7, width: 15, height: 22)).fill() // cut right half
    NSGraphicsContext.current!.cgContext.setBlendMode(.normal)
    black.setFill()
    NSBezierPath(roundedRect: CGRect(x: 22, y: 5, width: 6, height: 26), xRadius: 3, yRadius: 3).fill() // edge bar
    save(out, "menu-M2-orb-bar")
}

// M3: bold ring (the ◉, but properly sized as an image)
do {
    let (img, ctx) = menuCanvas()
    _ = ctx
    black.setStroke()
    let ring = NSBezierPath(ovalIn: CGRect(x: 8, y: 8, width: 20, height: 20))
    ring.lineWidth = 5
    ring.stroke()
    save(img, "menu-M3-ring")
}

// MARK: - menu preview strip: each candidate at real 18pt size on dark + light
do {
    let W: CGFloat = 720, H: CGFloat = 200
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    // dark bar (top), light bar (bottom)
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: H / 2, width: W, height: H / 2)).fill()
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H / 2)).fill()
    let names = ["menu-M1-eclipse-dot", "menu-M2-orb-bar", "menu-M3-ring"]
    let labels = ["M1", "M2", "M3"]
    for (i, n) in names.enumerated() {
        let iconURL = URL(fileURLWithPath: "\(outDir)/\(n).png")
        guard let icon = NSImage(contentsOf: iconURL) else { continue }
        let x: CGFloat = 80 + CGFloat(i) * 240
        // dark row: white glyph; light row: black glyph (template behavior)
        for (row, tint) in [(0, NSColor.black), (1, NSColor.white)] {
            let y = row == 1 ? H / 2 + 14 : 14
            let tinted = NSImage(size: icon.size)
            tinted.lockFocus()
            tint.set()
            NSBezierPath(rect: CGRect(origin: .zero, size: icon.size)).fill()
            icon.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
            tinted.unlockFocus()
            tinted.draw(in: CGRect(x: x, y: y, width: 36, height: 36))
        }
        // label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.gray,
        ]
        labels[i].draw(at: NSPoint(x: x + 4, y: 2), withAttributes: attrs)
    }
    save(img, "menu-preview")
}
print("done")
