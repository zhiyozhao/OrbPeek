import Foundation
import Testing
@testable import OrbPeekCore

@Suite("interaction after suspension")
@MainActor
struct ResumeInteractionTests {
    private func stripPoint(_ h: DisplayRulesV2Tests.Harness) -> CGPoint {
        let rect = h.delegate.geometry.sliverRect(edge: h.managed.edge, size: h.window.frame!.size,
            perp: h.managed.perp, screen: DisplayRulesV2Tests.Harness.a, thickness: h.delegate.config.sliverPx)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    @Test("unchanged desktop resumes hover within its normal dwell, without waiting three seconds", arguments: ["lock", "sleep", "inactive", "screensaver"])
    func immediateHover(gate: String) async {
        let h = await DisplayRulesV2Tests.Harness()
        let point = stripPoint(h)
        switch gate {
        case "lock": h.session.lock()
        case "sleep": h.session.sleep()
        case "inactive": h.session.setSessionActive(false)
        default: h.session.setScreenSaverActive(true)
        }
        let writes = h.window.positionWrites.count
        h.session.poll(mouseQ: point)
        #expect(h.window.positionWrites.count == writes)
        switch gate {
        case "lock": h.session.unlock()
        case "sleep": h.session.wake()
        case "inactive": h.session.setSessionActive(true)
        default: h.session.setScreenSaverActive(false)
        }
        #expect(h.session.canWriteAutomatically)
        h.session.poll(mouseQ: point)
        h.clock.advance(h.delegate.config.peekDwell - 0.01)
        h.session.poll(mouseQ: point)
        #expect(h.managed.phase == .docked)
        h.clock.advance(0.02)
        h.session.poll(mouseQ: point)
        #expect(h.managed.phase == .peeked)
        #expect(h.session.unreachableWindows().isEmpty)
    }

    @Test("unchanged unlock immediately permits slam and direct shortcut entry", arguments: [false, true])
    func immediateEntry(shortcut: Bool) async {
        let h = await DisplayRulesV2Tests.Harness()
        h.session.lock(); h.session.unlock()
        if shortcut { h.managed.peek() }
        else { h.session.poll(mouseQ: stripPoint(h), mouseVelocity: CGPoint(x: 0, y: 2000)) }
        #expect(h.managed.phase == .peeked)
    }

    @Test("unchanged resume repairs system drift without activating before permitting interaction", arguments: [false, true])
    func repairBeforeInteraction(peeked: Bool) async {
        let h = await DisplayRulesV2Tests.Harness()
        if peeked { h.managed.peek() }
        let original = h.window.frame
        let activations = h.delegate.activationCount
        h.session.lock()
        h.window.storedFrame?.origin.x = 0
        h.session.unlock()
        #expect(h.session.canWriteAutomatically)
        #expect(h.window.frame == original)
        #expect(h.managed.phase == (peeked ? .peeked : .docked))
        #expect(h.delegate.activationCount == activations)
        #expect(h.session.unreachableWindows().isEmpty)
    }

    @Test("a stationary pointer starts fresh dwell on the first settled poll, without leaving the strip", arguments: ["settle", "changed-unlock"])
    func stationaryOnResume(kind: String) async {
        let h = await DisplayRulesV2Tests.Harness()
        let point = stripPoint(h)
        h.session.poll(mouseQ: point) // A partial pre-pause dwell must not survive.
        h.clock.advance(0.1)
        if kind == "changed-unlock" { h.session.lock() }
        let a = DisplayRulesV2Tests.Harness.a
        let changed = ScreenInfo(id: a.id, frame: a.frame,
            visibleFrame: CGRect(x: 0, y: 10, width: 1920, height: 1045), displayUUID: a.displayUUID)
        h.change([changed, DisplayRulesV2Tests.Harness.b])
        if kind == "changed-unlock" { h.session.unlock() }
        let writes = h.window.positionWrites.count
        h.clock.advance(2.9)
        h.session.poll(mouseQ: point)
        #expect(!h.session.canWriteAutomatically)
        #expect(h.window.positionWrites.count == writes)
        h.clock.advance(0.2)
        // Use the new strip center and then keep it exactly stationary.
        let rect = h.delegate.geometry.sliverRect(edge: .down, size: h.window.frame!.size,
            perp: h.managed.perp, screen: changed, thickness: h.delegate.config.sliverPx)
        let currentPoint = CGPoint(x: rect.midX, y: rect.midY)
        h.session.poll(mouseQ: currentPoint)
        #expect(h.managed.phase == .docked)
        h.clock.advance(h.delegate.config.peekDwell + 0.01)
        h.session.poll(mouseQ: currentPoint)
        #expect(h.managed.phase == .peeked)
        #expect(h.session.unreachableWindows().isEmpty)
    }

    @Test("an outstanding configuration blocks fast resume and a later event closes interaction again")
    func configurationRace() async {
        let h = await DisplayRulesV2Tests.Harness()
        h.session.lock(); h.session.reconfigurationBegan(); h.session.unlock()
        #expect(!h.session.canWriteAutomatically)
        h.session.reconfigurationEnded(); h.poll(3.1)
        #expect(h.session.canWriteAutomatically)
        h.session.lock(); h.session.unlock()
        #expect(h.session.canWriteAutomatically)
        let writes = h.window.positionWrites.count
        h.change([DisplayRulesV2Tests.Harness.internalScreen])
        h.managed.peek()
        h.session.poll(mouseQ: .zero)
        #expect(h.window.positionWrites.count == writes)
        #expect(!h.session.canWriteAutomatically)
        h.poll(10.1)
        #expect(h.session.windows.isEmpty)
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
    }
}
