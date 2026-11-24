import Foundation
import Testing
@testable import OrbPeekCore

@Suite("independent session write gates")
@MainActor
struct IndependentSessionGateTests {
    @Test("each suspension alone blocks non-poll writes after settling expires", arguments: ["sleep", "inactive", "screensaver"])
    func directWriteGates(gate: String) async {
        let h = await DisplayRulesV2Tests.Harness()
        switch gate {
        case "sleep": h.session.sleep()
        case "inactive": h.session.setSessionActive(false)
        default: h.session.setScreenSaverActive(true)
        }
        // No lock or overlapping gate may mask a missing individual guard.
        #expect(!h.session.screenLocked)
        #expect(h.session.sleeping == (gate == "sleep"))
        #expect(h.session.sessionActive == (gate != "inactive"))
        #expect(h.session.screenSaverActive == (gate == "screensaver"))
        h.clock.advance(20)
        #expect(!h.session.settling.isSettling(at: h.clock.now))
        #expect(!h.session.canWriteAutomatically)
        let parked = h.window.frame
        let writes = h.window.positionWrites.count
        let sizes = h.window.sizeWrites.count

        // restore/terminate have no layoutDecisionPending guard; add() creates
        // an idle window. Only the shared write gate protects these entries.
        h.managed.restore()
        h.managed.terminate(exit: .restore)
        h.managed.peek()
        let other = FakeWindow(frame: CGRect(x: 400, y: 200, width: 500, height: 400))
        _ = h.session.add(window: other, edge: .down) { $0.isLeftMousePressed = { false } }
        await drainTasks()
        #expect(h.window.frame == parked)
        #expect(h.window.positionWrites.count == writes)
        #expect(h.window.sizeWrites.count == sizes)
        #expect(h.window.raiseCount == 0)
        #expect(h.delegate.activationCount == 0)
        #expect(h.delegate.removed.isEmpty)
        #expect(other.positionWrites.isEmpty && other.sizeWrites.isEmpty)
        #expect(h.session.windows.count == 2)

        switch gate {
        case "sleep": h.session.wake()
        case "inactive": h.session.setSessionActive(true)
        default: h.session.setScreenSaverActive(false)
        }
        h.poll(3.1)
        await drainTasks()
        #expect(h.session.canWriteAutomatically)
        #expect(!other.positionWrites.isEmpty)
        h.managed.peek()
        #expect(h.window.positionWrites.count > writes)
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) >= 0.99)
    }
}
