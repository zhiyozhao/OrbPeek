import CoreGraphics
import Testing
@testable import OrbPeekCore

@Suite("R1-4 screen-relative window coordinates")
@MainActor
struct RelativeCoordinateTests {
    @Test("restore frame follows the recorded screen when global origin moves")
    func restoreAfterPrimaryChange() async {
        let secondaryFrame = CGRect(x: 2200, y: 200, width: 700, height: 500)
        let fixture = await makeDockedFixture(layout: testLayout, frame: secondaryFrame)
        let translatedSecondary = ScreenInfo(
            id: 2,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        fixture.delegate.layoutBox.layout = ScreenLayout(screens: [translatedSecondary])

        fixture.managed.peek()
        #expect(fixture.window.storedFrame?.origin.x == 280)
        fixture.managed.terminate(exit: .restore)
        #expect(fixture.window.storedFrame?.origin == CGPoint(x: 280, y: 200))
    }

    @Test("peek and re-dock on fallback screen do not replace dock screen identity")
    func offlineRedockKeepsOriginalScreen() async {
        let secondaryFrame = CGRect(x: 2200, y: 200, width: 700, height: 500)
        let fixture = await makeDockedFixture(layout: testLayout, frame: secondaryFrame)
        fixture.delegate.layoutBox.layout = ScreenLayout(screens: [testPrimary])

        fixture.managed.peek()
        #expect(fixture.window.storedFrame?.origin.x == 280)
        fixture.managed.dock()
        await drainTasks()
        fixture.delegate.layoutBox.layout = testLayout
        tick(fixture, settling: true)

        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.window.storedFrame?.origin.x == 3839)
        #expect(fixture.managed.restoreFrame.origin == secondaryFrame.origin)
    }
}
