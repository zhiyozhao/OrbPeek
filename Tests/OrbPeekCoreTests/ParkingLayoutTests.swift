import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("R1-5 parking geometry across layout changes")
struct ParkingLayoutTests {
    @Test("outer-edge parking jump is deterministic and reverses when display returns")
    func hiddenPositionAcrossDisplayRemoval() {
        let size = CGSize(width: 700, height: 500)
        let perpOffset: CGFloat = 300
        let geometry = WindowGeometry(layout: testLayout)
        let twoScreenPosition = geometry.hiddenPosition(for: .down, size: size,
                                                        perp: perpOffset, screen: testPrimary)
        #expect(twoScreenPosition == CGPoint(x: -699, y: 580))

        let primaryOnly = ScreenLayout(screens: [testPrimary])
        let reducedGeometry = WindowGeometry(layout: primaryOnly)
        let reducedPosition = reducedGeometry.hiddenPosition(for: .down, size: size,
                                                             perp: perpOffset, screen: testPrimary)
        #expect(reducedPosition == CGPoint(x: 1919, y: 580))

        let restoredGeometry = WindowGeometry(layout: testLayout)
        #expect(restoredGeometry.hiddenPosition(for: .down, size: size,
                                                perp: perpOffset, screen: testPrimary) == twoScreenPosition)
    }
}
