import CoreGraphics
import Testing
@testable import OrbPeekCore

private let smallPrimary = ScreenInfo(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 800, height: 600),
    visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
)

private func isFullyVisible(_ frame: CGRect?, layout: ScreenLayout) -> Bool {
    guard let frame else { return false }
    return layout.screens.contains { screen in
        WindowGeometry(layout: layout).quartzVisibleFrame(of: screen).contains(frame)
    }
}

@Suite("undock safety net")
@MainActor
struct UndockSafetyTests {
    @Test("menu cancel restores into a smaller visible frame and shrinks when needed")
    func menuCancel() async {
        let fixture = await makeDockedFixture(layout: testLayout,
                                              frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        fixture.delegate.layoutBox.layout = ScreenLayout(screens: [smallPrimary])
        fixture.managed.terminate(exit: .restore)
        #expect(isFullyVisible(fixture.window.storedFrame, layout: fixture.delegate.layoutBox.layout))
        #expect(fixture.window.storedFrame?.size == CGSize(width: 800, height: 600))
    }

    @Test("quit/signal restore uses the same visible-area safety net")
    func quitRestore() async {
        let fixture = await makeDockedFixture(layout: testLayout,
                                              frame: CGRect(x: 1500, y: 200, width: 700, height: 500))
        fixture.delegate.layoutBox.layout = ScreenLayout(screens: [smallPrimary])
        fixture.managed.restore()
        #expect(isFullyVisible(fixture.window.storedFrame, layout: fixture.delegate.layoutBox.layout))
    }

    @Test("drag-out cannot leave a released window partially off-screen")
    func dragOut() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.window.storedFrame = CGRect(x: 1500, y: 539, width: 700, height: 500)
        fixture.managed.checkDragOut()
        #expect(fixture.delegate.removed.count == 1)
        #expect(isFullyVisible(fixture.window.storedFrame, layout: testLayout))
    }

    @Test("display removal followed by docked drift release fits the remaining screen")
    func unplugAndDriftRelease() async {
        let frame = CGRect(x: 2200, y: 200, width: 700, height: 500)
        let fixture = await makeDockedFixture(layout: testLayout, frame: frame)
        fixture.delegate.layoutBox.layout = ScreenLayout(screens: [testPrimary])
        tick(fixture)
        fixture.clock.advance(0.6)
        tick(fixture)
        #expect(fixture.delegate.removed.count == 1)
        #expect(isFullyVisible(fixture.window.storedFrame, layout: fixture.delegate.layoutBox.layout))
    }

    @Test("peeked drift release chooses the nearest screen")
    func peekedDriftRelease() async {
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.peek()
        fixture.clock.advance(1)
        fixture.window.storedFrame = CGRect(x: 4000, y: 480, width: 700, height: 500)
        tick(fixture)
        fixture.clock.advance(0.6)
        tick(fixture)
        #expect(fixture.delegate.removed.count == 1)
        #expect(isFullyVisible(fixture.window.storedFrame, layout: testLayout))
        #expect(fixture.window.storedFrame?.maxX == 3840)
    }

    @Test("capture interruption cannot leave the window off-screen")
    func captureInterruption() async {
        let fixture = makeIdleFixture(layout: testLayout)
        fixture.delegate.fakeCapturer.onCapture = {
            fixture.window.storedFrame?.origin = CGPoint(x: 4000, y: 200)
        }
        fixture.managed.dock()
        await drainTasks()
        #expect(fixture.delegate.removed.count == 1)
        #expect(isFullyVisible(fixture.window.storedFrame, layout: testLayout))
    }

    @Test("minimize and app-hide releases restore visibly on a smaller screen", arguments: [false, true])
    func tuckedAway(minimized: Bool) async {
        let fixture = await makeDockedFixture(layout: testLayout,
                                              frame: CGRect(x: 1500, y: 200, width: 700, height: 500))
        fixture.delegate.layoutBox.layout = ScreenLayout(screens: [smallPrimary])
        fixture.window.minimized = minimized
        fixture.window.appHidden = !minimized
        tick(fixture)
        #expect(fixture.delegate.removed.count == 1)
        #expect(isFullyVisible(fixture.window.storedFrame, layout: fixture.delegate.layoutBox.layout))
    }

    @Test("unreadable-window drop makes a best-effort visible restore")
    func unreadableWindow() async {
        let fixture = await makeDockedFixture(layout: testLayout,
                                              frame: CGRect(x: 1500, y: 200, width: 700, height: 500))
        fixture.delegate.layoutBox.layout = ScreenLayout(screens: [smallPrimary])
        fixture.delegate.fakeCapturer.windowIsInWindowList = false
        fixture.window.storedFrame = nil
        for _ in 0..<31 { tick(fixture) }
        #expect(fixture.delegate.removed.count == 1)
        #expect(isFullyVisible(fixture.window.storedFrame, layout: fixture.delegate.layoutBox.layout))
    }

    @Test("docked window on an unplugged screen re-docks to the remaining screen while settling")
    func unplugWhileSettling() async {
        let fixture = await makeDockedFixture(layout: testLayout,
                                              frame: CGRect(x: 2200, y: 200, width: 700, height: 500))
        fixture.delegate.layoutBox.layout = ScreenLayout(screens: [testPrimary])
        tick(fixture, settling: true)
        #expect(fixture.delegate.removed.isEmpty)
        #expect(fixture.managed.phase == .docked)
        let expected = fixture.delegate.geometry.hiddenPosition(for: .down, size: fixture.window.storedFrame!.size,
                                                                perp: fixture.managed.perp, screen: testPrimary)
        #expect(fixture.window.storedFrame?.origin == expected)
    }
}
