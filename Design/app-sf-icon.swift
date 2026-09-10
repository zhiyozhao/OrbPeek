// Renders app-icon variants: big menubar.dock.rectangle symbol on the indigo
// squircle, 3 weight/size variants side by side. Output: Design/proposals/app-sf-variants.png
import AppKit

let S: CGFloat = 1024
let inset: CGFloat = 64
let iconRect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)

func renderIcon(symbolPointSize: CGFloat, weight: NSFont.Weight, glow: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let squircle = NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208)
    ctx.saveGState()
    squircle.addClip()

    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.34, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1),
    ])!.draw(in: squircle, angle: -55)

    // soft top-left glow
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.72, alpha: 0.5).cgColor,
                                NSColor(white: 0, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: 300, y: 760), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 760), endRadius: 620, options: [])

    guard let sym = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: symbolPointSize, weight: weight)) else {
        fatalError("symbol missing")
    }
    // tint white
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    NSColor(white: 1, alpha: 0.96).set()
    NSBezierPath(rect: CGRect(origin: .zero, size: sym.size)).fill()
    sym.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()

    if glow {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 46,
                      color: NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 0.65).cgColor)
        tinted.draw(in: CGRect(x: (S - tinted.size.width) / 2, y: (S - tinted.size.height) / 2,
                               width: tinted.size.width, height: tinted.size.height))
        ctx.restoreGState()
    } else {
        tinted.draw(in: CGRect(x: (S - tinted.size.width) / 2, y: (S - tinted.size.height) / 2,
                               width: tinted.size.width, height: tinted.size.height))
    }

    ctx.restoreGState()
    img.unlockFocus()
    return img
}

let variants: [(CGFloat, NSFont.Weight, Bool, String)] = [
    (520, .regular, false, "A: 520 regular"),
    (520, .medium, true, "B: 520 medium + glow"),
    (620, .light, false, "C: 620 light"),
]

let gap: CGFloat = 32
let sheet = NSImage(size: NSSize(width: S * 3 + gap * 4, height: S + gap * 2 + 60))
sheet.lockFocus()
NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
NSBezierPath(rect: CGRect(origin: .zero, size: sheet.size)).fill()

for (i, v) in variants.enumerated() {
    let icon = renderIcon(symbolPointSize: v.0, weight: v.1, glow: v.2)
    let x = gap + CGFloat(i) * (S + gap)
    icon.draw(in: CGRect(x: x, y: gap + 60, width: S, height: S))
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 34, weight: .medium),
        .foregroundColor: NSColor.darkGray,
    ]
    v.3.draw(at: NSPoint(x: x + 8, y: 12), withAttributes: attrs)
}
sheet.unlockFocus()

let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: "Design/proposals/app-sf-variants.png"))
print("wrote Design/proposals/app-sf-variants.png")
