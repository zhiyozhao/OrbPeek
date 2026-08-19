// Renders all of OrbPeek's icon assets into Resources/Assets.xcassets from ONE
// mark definition (the "slit"): the AppIcon appiconset (all mac sizes) and the
// MenuIcon imageset (template rendering). build.sh compiles the catalog with
// `xcrun actool` into Assets.car — the canonical Apple pipeline.
// Usage: swift make-icon.swift
import AppKit
import Foundation

let resDir = "Resources/Assets.xcassets"
let fm = FileManager.default

// Render into an explicit pixel-exact bitmap — NSImage(size:)+lockFocus
// follows the display's backing scale (Retina doubles the pixels), which is
// how 18pt assets silently became 36px and broke the catalog's scale math.
func exactBitmap(px: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: app icon at a given pixel size
func appIconRep(px: Int) -> NSBitmapImageRep {
    exactBitmap(px: px) { ctx in
    // Apple's icon grid: the squircle occupies 824/1024 of the canvas
    // (~100px transparent margin per side at 1024) — filling more reads as
    // visibly larger than every other icon in the Dock/Finder.
    let inset = CGFloat(px) * 100.0 / 1024.0
    let L = CGFloat(px) - inset * 2
    let sq = NSBezierPath(roundedRect: CGRect(x: inset, y: inset, width: L, height: L),
                          xRadius: L * 0.2237, yRadius: L * 0.2237)
    ctx.saveGState()
    sq.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(calibratedRed: 0.945, green: 0.945, blue: 0.96, alpha: 1),
    ])!.draw(in: sq, angle: -90)
    let barW = L / 8
    let barH = L * 0.618
    let barRect = CGRect(x: inset + L * 2 / 3 - barW / 2, y: inset + (L - barH) / 2,
                         width: barW, height: barH)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(px) * 0.0137), blur: CGFloat(px) * 0.039,
                  color: NSColor(white: 0, alpha: 0.25).cgColor)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: barRect, xRadius: barW / 2, yRadius: barW / 2).fill()
    ctx.restoreGState()
    ctx.restoreGState()
    }
}

// MARK: menu-bar template mark at a given pixel size (black + alpha)
// Canvas is 18pt; the glyph is 15pt — a filled rounded square is optically
// heavier than a circle, so it sits slightly below bjango's 16pt circular
// reference to match system items' visual weight.
func menuIconRep(px: Int) -> NSBitmapImageRep {
    exactBitmap(px: px) { ctx in
    let u = CGFloat(px) / 18
    let g0 = 1.5 * u, g = 15 * u // glyph origin/size
    NSColor.black.setFill()
    NSBezierPath(roundedRect: CGRect(x: g0, y: g0, width: g, height: g),
                 xRadius: 4.3 * u, yRadius: 4.3 * u).fill()
    ctx.setBlendMode(.clear)
    let slitW = 3.4 * u, slitH = 9.4 * u
    let slitCX = g0 + g * 2 / 3
    NSBezierPath(roundedRect: CGRect(x: slitCX - slitW / 2, y: u * 9 - slitH / 2,
                                     width: slitW, height: slitH),
                 xRadius: slitW / 2, yRadius: slitW / 2).fill()
    }
}

func writePNG(_ rep: NSBitmapImageRep, _ path: String) {
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed: \(path)")
    }
    try! png.write(to: URL(fileURLWithPath: path))
}

func writeJSON(_ obj: [String: Any], _ path: String) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
}

// MARK: AppIcon.appiconset
let appiconDir = "\(resDir)/AppIcon.appiconset"
try! fm.createDirectory(atPath: appiconDir, withIntermediateDirectories: true)
// (size in points, scale)
let macSlots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var appiconImages: [[String: Any]] = []
for (pt, scale) in macSlots {
    let name = "appicon-\(pt)@\(scale)x.png"
    writePNG(appIconRep(px: pt * scale), "\(appiconDir)/\(name)")
    appiconImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
}
writeJSON(["images": appiconImages, "info": ["author": "xcode", "version": 1]],
          "\(appiconDir)/Contents.json")

// MARK: MenuIcon.imageset (template)
let menuDir = "\(resDir)/MenuIcon.imageset"
try! fm.createDirectory(atPath: menuDir, withIntermediateDirectories: true)
var menuImages: [[String: Any]] = [["idiom": "universal", "scale": "1x", "filename": "menuicon.png"],
                                   ["idiom": "universal", "scale": "2x", "filename": "menuicon@2x.png"],
                                   ["idiom": "universal", "scale": "3x", "filename": "menuicon@3x.png"]]
writePNG(menuIconRep(px: 18), "\(menuDir)/menuicon.png")
writePNG(menuIconRep(px: 36), "\(menuDir)/menuicon@2x.png")
writePNG(menuIconRep(px: 54), "\(menuDir)/menuicon@3x.png")
writeJSON(["images": menuImages,
           "info": ["author": "xcode", "version": 1],
           "properties": ["template-rendering-intent": "template"]],
          "\(menuDir)/Contents.json")

// MARK: catalog root
writeJSON(["info": ["author": "xcode", "version": 1]], "\(resDir)/Contents.json")
print("wrote \(resDir) (AppIcon.appiconset: \(macSlots.count) PNGs, MenuIcon.imageset: 3 PNGs)")
