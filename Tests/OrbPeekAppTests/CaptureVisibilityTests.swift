import CoreGraphics
import Testing
import AppKit
import OrbPeekCore
@testable import OrbPeek

@Suite("composited preview visibility")
struct CaptureVisibilityTests {
    let frame = CGRect(x: 200, y: 200, width: 300, height: 400)
    @Test("Pets Therapy's full-screen layer-3 alpha-1 sharing-none surface does not block a normal window")
    func petsOverlay() {
        let target = CaptureLayer(id: 534, pid: 10, frame: frame, alpha: 1)
        let pet = CaptureLayer(id: 21217, pid: 6829, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 1, layer: 3)
        #expect(CaptureVisibility.allows(frame: frame, target: 534, excludingPID: 30, layers: [pet, target]))
    }

    @Test("non-normal floating, alpha-zero, menu and Dock surfaces are decorations; normal translucent windows still block")
    func decorationKinds() {
        let target = CaptureLayer(id: 1, pid: 10, frame: frame, alpha: 1)
        for overlay in [
            CaptureLayer(id: 2, pid: 20, frame: frame, alpha: 1, layer: 3),
            CaptureLayer(id: 3, pid: 20, frame: frame, alpha: 0),
            CaptureLayer(id: 4, pid: 20, frame: frame, alpha: 1, layer: 24),
            CaptureLayer(id: 5, pid: 20, frame: frame, alpha: 1, layer: 20),
            CaptureLayer(id: 6, pid: 20, frame: frame, alpha: 1, systemDecoration: true)
        ] {
            #expect(CaptureVisibility.allows(frame: frame, target: 1, excludingPID: 30, layers: [overlay, target]))
        }
        for alpha in [0.01, 0.5, 1.0] {
            let blocker = CaptureLayer(id: 9, pid: 20, frame: frame, alpha: alpha)
            #expect(!CaptureVisibility.allows(frame: frame, target: 1, excludingPID: 30, layers: [blocker, target]))
        }
        #expect(CaptureVisibility.allows(frame: frame, target: 4, excludingPID: 30,
            layers: [CaptureLayer(id: 4, pid: 20, frame: frame, alpha: 1, layer: 3)]))
    }

    @Test("an explicitly targeted floating window is retained while other decorations are excluded")
    func floatingTarget() throws {
        let target = CaptureLayer(id: 10, pid: 20, frame: frame, alpha: 1, layer: 3)
        let pet = CaptureLayer(id: 11, pid: 20, frame: frame, alpha: 1, layer: 25)
        let ordinary = CaptureLayer(id: 12, pid: 40, frame: frame, alpha: 1)
        let list = [pet, target, ordinary]
        let windows = list.map { CaptureFilterWindow(id: $0.id, pid: $0.pid, layer: $0.layer) }
        #expect(CaptureVisibility.allows(frame: frame, target: 10, excludingPID: 30, layers: list))
        let plan = try CaptureFilterPlan.make(frame: frame, layers: list, ownPID: 30,
            availableApplications: [20, 30, 40], windows: windows, target: 10)
        #expect(plan.applications == [20, 30])
        #expect(plan.exceptions == [10]) // Target included, pet excluded.
        #expect(throws: (any Error).self) {
            try CaptureFilterPlan.make(frame: frame, layers: [ordinary, pet, target], ownPID: 30,
                availableApplications: [20, 30, 40], windows: windows, target: 10)
        }
        #expect(throws: (any Error).self) {
            try CaptureFilterPlan.make(frame: frame, layers: list, ownPID: 30,
                availableApplications: [20, 30, 40], windows: windows.filter { $0.id != 10 }, target: 10)
        }
        for invalid in [CaptureLayer(id: 10, pid: 20, frame: frame, alpha: 0, layer: 3),
                        CaptureLayer(id: 10, pid: 20, frame: frame, alpha: 1, systemDecoration: true)] {
            #expect(!CaptureVisibility.allows(frame: frame, target: 10, excludingPID: 30, layers: [invalid]))
        }
    }

    @Test("filter excludes Pets even without a shareable SCWindow, preserves its normal windows and the target composition")
    func filterPlan() throws {
        let layers = [
            CaptureLayer(id: 21217, pid: 6829, frame: frame, alpha: 1, layer: 3),
            CaptureLayer(id: 2, pid: 6829, frame: frame, alpha: 1), // Same app's normal settings window.
            CaptureLayer(id: 3, pid: 30, frame: frame, alpha: 0.5, layer: 3), // Our strip.
            CaptureLayer(id: 4, pid: 40, frame: frame, alpha: 1, layer: 24), // Menu bar.
            CaptureLayer(id: 5, pid: 50, frame: frame, alpha: 1, layer: 20), // Dock.
            CaptureLayer(id: 6, pid: 60, frame: frame, alpha: 0),
            CaptureLayer(id: 7, pid: 70, frame: frame, alpha: 1), // Target and ordinary background.
            CaptureLayer(id: 8, pid: 80, frame: frame, alpha: 1),
            CaptureLayer(id: 9, pid: 90, frame: frame, alpha: 1, layer: Int(CGWindowLevelForKey(.desktopWindow)))
        ]
        let windows = layers.filter { $0.id != 21217 }.map { CaptureFilterWindow(id: $0.id, pid: $0.pid, layer: $0.layer) }
        let plan = try CaptureFilterPlan.make(frame: frame, layers: layers, ownPID: 30,
            availableApplications: [6829, 30, 40, 50, 60, 70, 80, 90], windows: windows)
        #expect(plan.applications == [6829, 30, 40, 50, 60])
        #expect(plan.exceptions == [2]) // Include normal settings, not decorations or target.
        #expect(!plan.applications.contains(70))
        #expect(!plan.applications.contains(80))
        #expect(!plan.applications.contains(90)) // Desktop backing stays composed.
        // An owner with both a desktop backing surface and decoration must
        // keep the backing surface as an inclusion exception.
        let mixed = try CaptureFilterPlan.make(frame: frame,
            layers: [CaptureLayer(id: 10, pid: 90, frame: frame, alpha: 1, layer: 3), layers.last!], ownPID: 30,
            availableApplications: [30, 90], windows: [CaptureFilterWindow(id: 9, pid: 90, layer: Int(CGWindowLevelForKey(.desktopWindow)))])
        #expect(mixed.exceptions == [9])
    }

    @Test("unknown overlay or a missing normal exception requests fresh content instead of photographing the overlay")
    func staleFilter() throws {
        let overlay = CaptureLayer(id: 1, pid: 20, frame: frame, alpha: 1, layer: 3)
        #expect(throws: (any Error).self) {
            try CaptureFilterPlan.make(frame: frame, layers: [overlay], ownPID: 30, availableApplications: [30], windows: [])
        }
        let normal = CaptureLayer(id: 2, pid: 20, frame: frame, alpha: 1)
        #expect(throws: (any Error).self) {
            try CaptureFilterPlan.make(frame: frame, layers: [overlay, normal], ownPID: 30,
                availableApplications: [20, 30], windows: [])
        }
        let plan = try CaptureFilterPlan.make(frame: frame, layers: [overlay, normal], ownPID: 30,
            availableApplications: [20, 30], windows: [CaptureFilterWindow(id: 2, pid: 20, layer: 0)])
        #expect(plan.applications == [20, 30])
        #expect(plan.exceptions == [2])
        // SCWindow-only entries can still be excluded if no application entry exists.
        let noApp = try CaptureFilterPlan.make(frame: frame, layers: [overlay], ownPID: 30,
            availableApplications: [30], windows: [CaptureFilterWindow(id: 1, pid: 20, layer: 3)])
        #expect(noApp.applications == [30])
        #expect(noApp.exceptions == [1])
    }
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
