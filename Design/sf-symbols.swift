// Renders a contact sheet of SF Symbol candidates for OrbPeek's icons.
// Usage: swiftc -O -o /tmp/sfsymbols Design/sf-symbols.swift && /tmp/sfsymbols
import AppKit

let symbols: [String] = [
    "circle.lefthalf.filled",
    "circle.righthalf.filled",
    "eye",
    "eye.fill",
    "arrow.left.to.line",
    "arrow.right.to.line",
    "arrow.down.to.line",
    "arrow.up.to.line",
    "menubar.dock.rectangle",
    "menubar.rectangle",
    "macwindow",
    "pip",
    "cursorarrow.motionlines",
    "rectangle.lefthalf.inset.filled",
    "record.circle",
    "dot.circle",
]

let cellW: CGFloat = 320, cellH: CGFloat = 220
let cols = 4
let rows = (symbols.count + cols - 1) / cols
let W = cellW * CGFloat(cols), H = cellH * CGFloat(rows) + 10

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSColor.white.setFill()
NSBezierPath(rect: CGRect(x: 0, y: 0, width: W, height: H)).fill()

let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular),
    .foregroundColor: NSColor.darkGray,
]

for (i, name) in symbols.enumerated() {
    let col = CGFloat(i % cols), row = CGFloat(i / cols)
    let x = col * cellW, y = H - 10 - (row + 1) * cellH // top-down
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
        "(missing)".draw(at: NSPoint(x: x + 20, y: y + cellH / 2), withAttributes: labelAttrs)
        name.draw(at: NSPoint(x: x + 16, y: y + 16), withAttributes: labelAttrs)
        continue
    }
    let config = NSImage.SymbolConfiguration(pointSize: 96, weight: .regular)
    let sized = sym.withSymbolConfiguration(config) ?? sym
    let r = sized.size
    sized.draw(in: CGRect(x: x + (cellW - r.width) / 2, y: y + 52, width: r.width, height: r.height),
               from: .zero, operation: .sourceOver, fraction: 1)
    // centered label
    let labelSize = (name as NSString).size(withAttributes: labelAttrs)
    name.draw(at: NSPoint(x: x + (cellW - labelSize.width) / 2, y: y + 14), withAttributes: labelAttrs)
}
img.unlockFocus()

let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "Design/proposals/sf-symbols.png"))
print("wrote Design/proposals/sf-symbols.png")
