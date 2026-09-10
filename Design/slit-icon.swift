// App icon = enlarged slit: white squircle + a single dark vertical pill.
// 3 treatments: flat / glow / subtle gradient+shadow. Plus refined menu slit.
// Output: Design/proposals/slit-icon.png (3-up sheet), menu-slit-v2.png
import AppKit

let S: CGFloat = 1024
let inset: CGFloat = 64
let iconRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)

let pillDarkTop = NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.21, alpha: 1)
let pillDarkBottom = NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.12, alpha: 1)
let lightCore = NSColor(calibratedRed: 0.92, green: 0.99, blue: 1.0, alpha: 1)
let lightGlow = NSColor(calibratedRed: 0.45, green: 0.80, blue: 1.0, alpha: 1)

// pill geometry shared by all variants: right-of-center like the slit mark
let pillRect = CGRect(x: 588, y: 222, width: 68, height: 580)

func whiteCanvas() -> (NSImage, CGContext) {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let sq = NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208)
    ctx.saveGState()
    sq.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(calibratedRed: 0.945, green: 0.945, blue: 0.96, alpha: 1),
    ])!.draw(in: sq, angle: -90)
    return (img, ctx)
}

func done(_ img: NSImage, _ ctx: CGContext) -> NSImage {
    ctx.restoreGState(); img.unlockFocus()
    return img
}

func renderIcon(treatment: Int) -> NSImage {
    let (img, ctx) = whiteCanvas()
    let pill = NSBezierPath(roundedRect: pillRect, xRadius: 34, yRadius: 34)
    switch treatment {
    case 0: // flat
        NSColor(calibratedRed: 0.10, green: 0.105, blue: 0.16, alpha: 1).setFill()
        pill.fill()
    case 1: // glow (light through the crack)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 60, color: lightGlow.withAlphaComponent(0.85).cgColor)
        lightCore.setFill()
        pill.fill()
        ctx.restoreGState()
        lightCore.setFill()
        pill.fill()
    default: // subtle gradient + soft shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 34,
                      color: NSColor(white: 0, alpha: 0.22).cgColor)
        NSGradient(colors: [pillDarkTop, pillDarkBottom])!.draw(in: pill, angle: -90)
        ctx.restoreGState()
    }
    return done(img, ctx)
}

// 3-up sheet
do {
    let gap: CGFloat = 32
    let sheet = NSImage(size: NSSize(width: S * 3 + gap * 4, height: S + gap * 2 + 60))
    sheet.lockFocus()
    NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: sheet.size)).fill()
    let labels = ["A: flat", "B: glow", "C: gradient + shadow"]
    for i in 0 ..< 3 {
        let icon = renderIcon(treatment: i)
        let x = gap + CGFloat(i) * (S + gap)
        icon.draw(in: CGRect(x: x, y: gap + 60, width: S, height: S))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .medium),
            .foregroundColor: NSColor.darkGray,
        ]
        labels[i].draw(at: NSPoint(x: x + 8, y: 14), withAttributes: attrs)
    }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/slit-icon.png"))
}

// Refined menu slit: squarer-but-friendlier radius, optically placed slit,
// previewed at 18pt and 4x zoom, dark + light.
do {
    let W: CGFloat = 1280, H: CGFloat = 300
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: H / 2, width: W, height: H / 2)).fill()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H / 2)).fill()

    func slitMark(_ color: NSColor) -> NSImage {
        let m = NSImage(size: NSSize(width: 36, height: 36))
        m.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 6, y: 6, width: 24, height: 24), xRadius: 7, yRadius: 7).fill()
        NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
        // slit at ~62% x, spans 62% height, rounded ends
        NSBezierPath(roundedRect: CGRect(x: 21, y: 10.5, width: 4, height: 15), xRadius: 2, yRadius: 2).fill()
        m.unlockFocus()
        return m
    }
    for (row, color) in [NSColor.white, NSColor.black].enumerated() {
        let y = row == 0 ? H / 2 + 56 : 56
        // 18pt actual size
        slitMark(color).draw(in: CGRect(x: 300, y: y, width: 36, height: 36))
        // 4x zoom
        slitMark(color).draw(in: CGRect(x: 560, y: y - 54, width: 144, height: 144))
        // plain bar variant (the app-icon positive form) for comparison
        let bar = NSImage(size: NSSize(width: 36, height: 36))
        bar.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 21, y: 10.5, width: 4, height: 15), xRadius: 2, yRadius: 2).fill()
        bar.unlockFocus()
        bar.draw(in: CGRect(x: 860, y: y, width: 36, height: 36))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/menu-slit-v2.png"))
}
print("done")
