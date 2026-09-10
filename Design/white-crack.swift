// White-background app icon proposals: the "crack of light" slab on an
// off-white squircle (Apple-style near-white with a whisper of gradient).
// + menu-bar marks: slit inside vs notch on the edge.
// Output: Design/proposals/white-crack.png, menu-crack-preview.png
import AppKit

let S: CGFloat = 1024
let inset: CGFloat = 64
let iconRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)

let slabDark = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.16, alpha: 1)
let lightCore = NSColor(calibratedRed: 0.92, green: 0.99, blue: 1.0, alpha: 1)
let lightGlow = NSColor(calibratedRed: 0.45, green: 0.80, blue: 1.0, alpha: 1)

func whiteCanvas() -> (NSImage, CGContext) {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let sq = NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208)
    ctx.saveGState()
    sq.addClip()
    // near-white with a whisper of vertical gradient so the edge always reads
    NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.945, green: 0.945, blue: 0.96, alpha: 1), // ~#F1F1F5
    ])!.draw(in: sq, angle: -90)
    return (img, ctx)
}

// slab centered, slit near the slab's right side
func slabWithSlit(_ ctx: CGContext, glowing: Bool, slabTint: NSColor? = nil) {
    let slabRect = CGRect(x: 232, y: 232, width: 560, height: 560)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 44,
                  color: NSColor(white: 0, alpha: 0.25).cgColor)
    (slabTint ?? slabDark).setFill()
    NSBezierPath(roundedRect: slabRect, xRadius: 120, yRadius: 120).fill()
    ctx.restoreGState()

    let slitRect = CGRect(x: slabRect.maxX - 148, y: slabRect.minY + 108, width: 26, height: slabRect.height - 216)
    if glowing {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 56, color: lightGlow.withAlphaComponent(0.9).cgColor)
        lightCore.setFill()
        NSBezierPath(roundedRect: slitRect, xRadius: 13, yRadius: 13).fill()
        ctx.restoreGState()
        lightCore.setFill()
        NSBezierPath(roundedRect: slitRect, xRadius: 13, yRadius: 13).fill()
    } else {
        // flat: the slit is just the canvas showing through
        NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.975, alpha: 1).setFill()
        NSBezierPath(roundedRect: slitRect, xRadius: 13, yRadius: 13).fill()
    }
}

// V1: glowing crack
do {
    let (img, ctx) = whiteCanvas()
    slabWithSlit(ctx, glowing: true)
    ctx.restoreGState(); img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/white-V1-glow.png"))
}

// V2: flat crack (no glow)
do {
    let (img, ctx) = whiteCanvas()
    slabWithSlit(ctx, glowing: false)
    ctx.restoreGState(); img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/white-V2-flat.png"))
}

// MARK: menu-bar marks: slit inside vs edge notch, dark + light strips
do {
    let W: CGFloat = 1280, H: CGFloat = 260
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: H / 2, width: W, height: H / 2)).fill()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H / 2)).fill()

    // black rounded square, transparent slit inside (near right)
    func slitMark(_ color: NSColor) -> NSImage {
        let m = NSImage(size: NSSize(width: 36, height: 36))
        m.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 5, y: 5, width: 26, height: 26), xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
        NSBezierPath(roundedRect: CGRect(x: 22, y: 9, width: 4.5, height: 18), xRadius: 2.25, yRadius: 2.25).fill()
        m.unlockFocus()
        return m
    }
    // black rounded square, notch breaking the right edge
    func notchMark(_ color: NSColor) -> NSImage {
        let m = NSImage(size: NSSize(width: 36, height: 36))
        m.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 5, y: 5, width: 26, height: 26), xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
        NSBezierPath(rect: CGRect(x: 26.5, y: 9, width: 8, height: 18)).fill()
        m.unlockFocus()
        return m
    }
    let marks: [(String, (NSColor) -> NSImage)] = [("slit", slitMark), ("notch", notchMark)]
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
        .write(to: URL(fileURLWithPath: "Design/proposals/menu-crack-preview.png"))
}
print("done")
