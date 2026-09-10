// Two abstract directions for OrbPeek's icon:
//   1. "Crack of light" — a dark slab with a glowing slit on one edge
//   2. "Fin" — a fin rising above a waterline
// 2 variants each + menu-bar-size previews. Output: Design/proposals/directions.png
import AppKit

let S: CGFloat = 1024
let inset: CGFloat = 64
let iconRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)

func canvas() -> (NSImage, CGContext) {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let sq = NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208)
    ctx.saveGState()
    sq.addClip()
    return (img, ctx)
}

func finish(_ img: NSImage, _ ctx: CGContext) -> NSImage {
    ctx.restoreGState()
    img.unlockFocus()
    return img
}

func darkSlab() {
    NSGradient(colors: [
        NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.18, alpha: 1),
        NSColor(calibratedRed: 0.03, green: 0.035, blue: 0.06, alpha: 1),
    ])!.draw(in: NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208), angle: -60)
}

func indigoSlab() {
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.34, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1),
    ])!.draw(in: NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208), angle: -55)
}

func glow(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, color: NSColor) {
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
}

let lightCore = NSColor(calibratedRed: 0.92, green: 0.99, blue: 1.0, alpha: 1)
let lightGlow = NSColor(calibratedRed: 0.45, green: 0.80, blue: 1.0, alpha: 1)

// MARK: 1A — crack of light: thin bright slit near the right edge
do {
    let (img, ctx) = canvas()
    darkSlab()
    let slitX = iconRect.maxX - 190
    let slitRect = CGRect(x: slitX, y: iconRect.minY + 150, width: 22, height: iconRect.height - 300)
    // bloom
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: lightGlow.withAlphaComponent(0.9).cgColor)
    lightCore.setFill()
    NSBezierPath(roundedRect: slitRect, xRadius: 11, yRadius: 11).fill()
    ctx.restoreGState()
    // subtle floor spill at the slit's base
    glow(ctx, at: CGPoint(x: slitX + 11, y: iconRect.minY + 160), radius: 260,
         color: lightGlow.withAlphaComponent(0.30))
    // re-draw the crisp core on top
    lightCore.setFill()
    NSBezierPath(roundedRect: slitRect, xRadius: 11, yRadius: 11).fill()
    _ = finish(img, ctx)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/dir1A-crack.png"))
}

// MARK: 1B — light spill: slit with a fan of light spilling left into the room
do {
    let (img, ctx) = canvas()
    darkSlab()
    let slitX = iconRect.maxX - 190
    let slitRect = CGRect(x: slitX, y: iconRect.minY + 150, width: 22, height: iconRect.height - 300)
    // fan spill: horizontal gradient fading from the slit toward the left
    ctx.saveGState()
    let fan = NSBezierPath()
    fan.move(to: CGPoint(x: slitX, y: iconRect.minY + 150))
    fan.line(to: CGPoint(x: slitX, y: iconRect.maxY - 150))
    fan.line(to: CGPoint(x: iconRect.minX + 60, y: iconRect.maxY - 40))
    fan.line(to: CGPoint(x: iconRect.minX + 60, y: iconRect.minY + 40))
    fan.close()
    fan.addClip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [lightGlow.withAlphaComponent(0.55).cgColor,
                                lightGlow.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: slitX, y: 512), end: CGPoint(x: iconRect.minX + 60, y: 512), options: [])
    ctx.restoreGState()
    // slit core with bloom
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: lightGlow.withAlphaComponent(0.9).cgColor)
    lightCore.setFill()
    NSBezierPath(roundedRect: slitRect, xRadius: 11, yRadius: 11).fill()
    ctx.restoreGState()
    _ = finish(img, ctx)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/dir1B-spill.png"))
}

// MARK: fin shape helper (in a 640x500 box, baseline y=0)
func finPath() -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: 20, y: 0))
    // leading edge: convex rise to the tip
    p.curve(to: CGPoint(x: 430, y: 470),
            controlPoint1: CGPoint(x: 60, y: 300),
            controlPoint2: CGPoint(x: 250, y: 455))
    // rounded tip
    p.curve(to: CGPoint(x: 500, y: 415),
            controlPoint1: CGPoint(x: 470, y: 472),
            controlPoint2: CGPoint(x: 505, y: 455))
    // trailing edge: concave swoop back down
    p.curve(to: CGPoint(x: 640, y: 0),
            controlPoint1: CGPoint(x: 470, y: 240),
            controlPoint2: CGPoint(x: 430, y: 110))
    p.close()
    return p
}

func drawFinIcon(gradientFin: Bool) -> NSImage {
    let (img, ctx) = canvas()
    indigoSlab()
    glow(ctx, at: CGPoint(x: 300, y: 760), radius: 620,
         color: NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.72, alpha: 0.45))
    let fin = finPath()
    // center the 640x500 fin box, sitting on the waterline
    var tx = AffineTransform(translationByX: (S - 640) / 2, byY: 380)
    fin.transform(using: tx)
    let finColor0 = gradientFin ? NSColor(calibratedRed: 0.55, green: 0.90, blue: 1.0, alpha: 1) : NSColor(white: 1, alpha: 0.96)
    let finColor1 = gradientFin ? NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1) : NSColor(white: 1, alpha: 0.96)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 34, color: NSColor(white: 0, alpha: 0.4).cgColor)
    NSGradient(colors: [finColor0, finColor1])!.draw(in: fin, angle: 70)
    ctx.restoreGState()
    // waterline
    NSColor(white: 1, alpha: gradientFin ? 0.85 : 0.7).setFill()
    NSBezierPath(roundedRect: CGRect(x: (S - 560) / 2, y: 344, width: 560, height: 20),
                 xRadius: 10, yRadius: 10).fill()
    return finish(img, ctx)
}

do {
    let img = drawFinIcon(gradientFin: false)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/dir3A-fin-white.png"))
}
do {
    let img = drawFinIcon(gradientFin: true)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/dir3B-fin-gradient.png"))
}

// MARK: menu-bar-size preview sheet (template silhouettes, dark + light strips)
do {
    let W: CGFloat = 1280, H: CGFloat = 260
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: H / 2, width: W, height: H / 2)).fill()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H / 2)).fill()

    func crackMark(_ color: NSColor) -> NSImage {
        let m = NSImage(size: NSSize(width: 36, height: 36))
        m.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 6, y: 6, width: 24, height: 24), xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
        NSBezierPath(roundedRect: CGRect(x: 22, y: 9, width: 4, height: 18), xRadius: 2, yRadius: 2).fill()
        m.unlockFocus()
        return m
    }
    func finMark(_ color: NSColor) -> NSImage {
        let m = NSImage(size: NSSize(width: 36, height: 36))
        m.lockFocus()
        color.setFill()
        let f = finPath()
        var s = AffineTransform(scaleByX: 0.034, byY: 0.034)
        f.transform(using: s)
        var t = AffineTransform(translationByX: 5, byY: 12)
        f.transform(using: t)
        f.fill()
        NSBezierPath(roundedRect: CGRect(x: 5, y: 7, width: 26, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
        m.unlockFocus()
        return m
    }
    let marks: [(String, (NSColor) -> NSImage)] = [("crack", crackMark), ("fin", finMark)]
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .medium),
        .foregroundColor: NSColor.gray,
    ]
    for (row, color) in [NSColor.white, NSColor.black].enumerated() {
        for (i, m) in marks.enumerated() {
            let x = 260 + CGFloat(i) * 400
            let y = row == 0 ? H / 2 + 46 : 46
            m.1(color).draw(in: CGRect(x: x, y: y, width: 36, height: 36))
            m.0.draw(at: NSPoint(x: x + 48, y: y + 6), withAttributes: labelAttrs)
        }
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/dir-menu-preview.png"))
}
print("done")
