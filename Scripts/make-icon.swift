// Render OrbPeek's app icon: a dark screen with a window card sliding in
// from the right edge (title-bar side visible) plus the bright preview strip
// on that edge. Outputs a 1024x1024 PNG; usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// MARK: background squircle
let inset: CGFloat = 64
let iconRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: iconRect, xRadius: 208, yRadius: 208)

squircle.addClip()

let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.34, alpha: 1), // #2A3057 top-left
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.14, alpha: 1), // #0D1224 bottom-right
])!
bg.draw(in: squircle, angle: -55)

// soft radial glow, upper left
if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.72, alpha: 0.55).cgColor,
                                  NSColor(calibratedWhite: 0, alpha: 0).cgColor] as CFArray,
                         locations: [0, 1]) {
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: 300, y: 760), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 760), endRadius: 620,
                           options: [])
}

// MARK: window card sliding in from the right edge
ctx.saveGState()
squircle.addClip()
let cardRect = CGRect(x: 470, y: 290, width: 640, height: 460) // right part clipped by squircle
let card = NSBezierPath(roundedRect: cardRect, xRadius: 40, yRadius: 40)

// drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -14, height: -18), blur: 42,
              color: NSColor(white: 0, alpha: 0.45).cgColor)
NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.98, alpha: 1).setFill()
card.fill()
ctx.restoreGState()

// title bar
let titleH: CGFloat = 96
let titleRect = CGRect(x: cardRect.minX, y: cardRect.maxY - titleH, width: cardRect.width, height: titleH)
let titleClip = NSBezierPath(roundedRect: cardRect, xRadius: 40, yRadius: 40)
titleClip.addClip()
NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.93, alpha: 1).setFill()
titleRect.fill()

// traffic lights
let dotColors: [NSColor] = [
    NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
    NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),
]
for (i, c) in dotColors.enumerated() {
    c.setFill()
    NSBezierPath(ovalIn: CGRect(x: cardRect.minX + 44 + CGFloat(i) * 64,
                                y: cardRect.maxY - titleH / 2 - 22,
                                width: 44, height: 44)).fill()
}

// content lines
NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.88, alpha: 1).setFill()
for (i, w) in [360, 300, 336].enumerated() {
    NSBezierPath(roundedRect: CGRect(x: cardRect.minX + 44,
                                     y: cardRect.maxY - titleH - 84 - CGFloat(i) * 76,
                                     width: CGFloat(w), height: 34),
                 xRadius: 17, yRadius: 17).fill()
}

// MARK: preview strip on the right edge (the handle)
let stripRect = CGRect(x: iconRect.maxX - 66, y: 330, width: 54, height: 364)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: -8, height: 0), blur: 30,
              color: NSColor(calibratedRed: 0.25, green: 0.75, blue: 0.95, alpha: 0.8).cgColor)
let strip = NSBezierPath(roundedRect: stripRect, xRadius: 28, yRadius: 28)
let stripGrad = NSGradient(colors: [
    NSColor(calibratedRed: 0.42, green: 0.86, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.24, green: 0.55, blue: 0.95, alpha: 1),
])!
stripGrad.draw(in: strip, angle: 90)
ctx.restoreGState()
ctx.restoreGState()

image.unlockFocus()

// MARK: save
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
