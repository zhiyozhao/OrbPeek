import CoreGraphics
import Testing
import AppKit
import OrbPeekCore
@testable import OrbPeek

@Suite("composited preview visibility")
struct CaptureVisibilityTests {
    let frame = CGRect(x: 200, y: 200, width: 300, height: 400)
    @Test("window order, not frontmost app, decides whether pixels are safe")
    func layers() {
        let target = CaptureLayer(id: 1, pid: 10, frame: frame, alpha: 1)
        let overlap = CaptureLayer(id: 2, pid: 20, frame: frame, alpha: 1)
        let away = CaptureLayer(id: 3, pid: 20, frame: frame.offsetBy(dx: 500, dy: 0), alpha: 1)
        #expect(CaptureVisibility.allows(frame: frame, target: 1, excludingPID: 30, layers: [away, target]))
        #expect(CaptureVisibility.allows(frame: frame, target: 1, excludingPID: 30, layers: [target, overlap]))
        #expect(!CaptureVisibility.allows(frame: frame, target: 1, excludingPID: 30, layers: [overlap, target]))
        #expect(CaptureVisibility.allows(frame: frame, target: 1, excludingPID: 20, layers: [overlap, target]))
        #expect(!CaptureVisibility.allows(frame: frame, target: 1, excludingPID: 30, layers: [away]))
        #expect(!CaptureVisibility.allows(frame: frame.offsetBy(dx: 10, dy: 0), target: 1, excludingPID: 30, layers: [target]))
        let translucent = CaptureLayer(id: 4, pid: 20, frame: frame, alpha: 0.3)
        #expect(!CaptureVisibility.allows(frame: frame, target: 1, excludingPID: 30, layers: [translucent, target]))
    }

    @Test("identity placeholders render app text on every edge without a black empty image")
    @MainActor
    func identity() {
        for edge in [OrbPeekCore.DockEdge.left, .right, .up, .down] {
            let size = edge.slideAxis == .vertical ? CGSize(width: 300, height: 15) : CGSize(width: 15, height: 300)
            let image = StripIdentity.image(name: "Own Test", icon: nil, size: size, edge: edge)
            #expect(image.size == size)
            #expect(image.tiffRepresentation != nil)
        }
    }
}
