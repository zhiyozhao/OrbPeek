// Slit mark v2, one harmonic system at both sizes:
//   bar height = 0.618 L, width = L/8, center x = 2/3 L, stadium ends
// App icon: pure black bar on near-white, flat vs soft-shadow.
// Output: Design/proposals/slit-v2.png, menu-slit-v3.png
import AppKit

let S: CGFloat = 1024
let inset: CGFloat = 64
let L: CGFloat = S - inset * 2 // outer side = 896

let barW = L / 8
let barH = L * 0.618
let barCX = inset + L * 2 / 3
let barRect = CGRect(x: barCX - barW / 2, y: inset + (L - barH) / 2, width: barW, height: barH)
let bar = NSBezierPath(roundedRect: barRect, xRadius: barW / 2, yRadius: barW / 2)

func whiteCanvas() -> (NSImage, CGContext) {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let sq = NSBezierPath(roundedRect: CGRect(x: inset, y: inset, width: L, height: L), xRadius: 208, yRadius: 208)
    ctx.saveGState()
    sq.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(calibratedRed: 0.945, green: 0.945, blue: 0.96, alpha: 1),
    ])!.draw(in: sq, angle: -90)
    return (img, ctx)
}

// A: pure flat black
do {
    let (img, ctx) = whiteCanvas()
    NSColor.black.setFill()
    bar.fill()
    ctx.restoreGState(); img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/slit-v2-flat.png"))
}

// B: flat black + whisper of a shadow
do {
    let (img, ctx) = whiteCanvas()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
                  color: NSColor(white: 0, alpha: 0.25).cgColor)
    NSColor.black.setFill()
    bar.fill()
    ctx.restoreGState()
    ctx.restoreGState(); img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/slit-v2-shadow.png"))
}

// MARK: menu mark v3 — same ratios, optically bolded slit
do {
    let W: CGFloat = 1280, H: CGFloat = 300
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: H / 2, width: W, height: H / 2)).fill()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H / 2)).fill()

    func slitMark(_ color: NSColor) -> NSImage {
        // outer 24x24 @ (6,6); slit: h=15 (0.625), w=4.5, center at 2/3 of square
        let m = NSImage(size: NSSize(width: 36, height: 36))
        m.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: 6, y: 6, width: 24, height: 24), xRadius: 7, yRadius: 7).fill()
        NSGraphicsContext.current!.cgContext.setBlendMode(.clear)
        let slitW: CGFloat = 4.5, slitH: CGFloat = 15
        let slitCX: CGFloat = 6 + 24 * 2 / 3
        NSBezierPath(roundedRect: CGRect(x: slitCX - slitW / 2, y: 18 - slitH / 2, width: slitW, height: slitH),
                     xRadius: slitW / 2, yRadius: slitW / 2).fill()
        m.unlockFocus()
        return m
    }
    for (row, color) in [NSColor.white, NSColor.black].enumerated() {
        let y = row == 0 ? H / 2 + 56 : 56
        slitMark(color).draw(in: CGRect(x: 340, y: y, width: 36, height: 36))
        slitMark(color).draw(in: CGRect(x: 620, y: y - 54, width: 144, height: 144))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "Design/proposals/menu-slit-v3.png"))
}
print("done")
