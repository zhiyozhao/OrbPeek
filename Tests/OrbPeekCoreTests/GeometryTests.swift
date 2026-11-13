import CoreGraphics
import Testing
@testable import OrbPeekCore

private let primary = ScreenInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055)
)

@Suite("R1-3 coordinate conversion")
struct CoordinateConversionTests {
    @Test("same-size side-by-side layout")
    func sideBySide() {
        let external = ScreenInfo(id: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        let geometry = WindowGeometry(layout: ScreenLayout(screens: [primary, external]))
        #expect(geometry.toQuartz(CGPoint(x: 3000, y: 10)) == CGPoint(x: 3000, y: 1070))
    }

    @Test("external display left of primary keeps x unchanged")
    func externalOnLeft() {
        let external = ScreenInfo(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let geometry = WindowGeometry(layout: ScreenLayout(screens: [primary, external]))
        #expect(geometry.toQuartz(CGPoint(x: 1000, y: 10)) == CGPoint(x: 1000, y: 1070))
        #expect(geometry.toQuartz(CGPoint(x: -1000, y: 10)) == CGPoint(x: -1000, y: 1070))
    }

    @Test("taller bottom-aligned external display uses primary height")
    func tallerExternal() {
        let external = ScreenInfo(id: 2, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1440),
                                  visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1440))
        let geometry = WindowGeometry(layout: ScreenLayout(screens: [primary, external]))
        #expect(geometry.toQuartz(CGPoint(x: 1000, y: 10)) == CGPoint(x: 1000, y: 1070))
        #expect(geometry.quartzVisibleFrame(of: primary) == CGRect(x: 0, y: 25, width: 1920, height: 1055))
        #expect(geometry.quartzFrame(of: external) == CGRect(x: 1920, y: -360, width: 1920, height: 1440))
    }

    @Test("one-pixel vertical arrangement offset does not move coordinates")
    func onePixelOffset() {
        let external = ScreenInfo(id: 2, frame: CGRect(x: 1920, y: 1, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 1920, y: 1, width: 1920, height: 1080))
        let geometry = WindowGeometry(layout: ScreenLayout(screens: [primary, external]))
        #expect(geometry.toQuartz(CGPoint(x: 1000, y: 10)) == CGPoint(x: 1000, y: 1070))
    }

    @Test("AppKit and quartz conversions round-trip")
    func roundTrip() {
        let external = ScreenInfo(id: 2, frame: CGRect(x: -1920, y: 300, width: 1920, height: 1440),
                                  visibleFrame: CGRect(x: -1920, y: 300, width: 1920, height: 1440))
        let geometry = WindowGeometry(layout: ScreenLayout(screens: [primary, external]))
        let rect = CGRect(x: -500, y: -100, width: 800, height: 600)
        #expect(geometry.toAppKit(geometry.toAppKit(rect)) == rect)
        let point = CGPoint(x: -700, y: 200)
        #expect(geometry.toAppKit(geometry.toQuartz(point)) == point)
    }
}

private extension WindowGeometry {
    func toAppKit(_ point: CGPoint) -> CGPoint {
        toAppKit(CGRect(origin: point, size: .zero)).origin
    }
}
