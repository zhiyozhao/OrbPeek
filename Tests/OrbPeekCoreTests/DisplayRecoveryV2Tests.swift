import Foundation
import Testing
@testable import OrbPeekCore

@Suite("display rules launch recovery")
@MainActor
struct DisplayRecoveryV2Tests {
    @Test("launch recovery keeps journal during session/zero-screen/AX blackout")
    func recoveryGates() async throws {
        let h = await DisplayRulesV2Tests.Harness()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStateStore(fileURL: directory.appendingPathComponent("state.json"))
        let record = try #require(h.managed.persistenceRecord())
        try store.save([record])
        let recovery = DockRecovery(store: store)
        #expect(!recovery.recover(geometry: h.delegate.geometry, canWrite: { false }, resolver: { _ in [h.window] }))
        #expect(!recovery.recover(geometry: WindowGeometry(layout: ScreenLayout(screens: [ScreenInfo]())), resolver: { _ in [h.window] }))
        #expect(!recovery.recover(geometry: h.delegate.geometry, resolver: { _ in nil }))
        h.window.storedFrame = nil
        #expect(!recovery.recover(geometry: h.delegate.geometry, resolver: { _ in [h.window] }))
        #expect(try store.load() == [record])
        h.window.storedFrame = record.parkedFrame.rect
        #expect(recovery.recover(geometry: h.delegate.geometry, resolver: { _ in [h.window] }))
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
        #expect(try store.load().isEmpty)
    }

    @Test("upgrade recovery keeps all four edges including inner edges after runtime IDs are reassigned", arguments: [DockEdge.left, .right, .up, .down])
    func upgradeWithNewID(edge: DockEdge) async throws {
        let h = await DisplayRulesV2Tests.Harness(edge: edge)
        h.window.windowID = 7
        let expected = h.window.frame
        h.managed.restore()
        let record = try #require(h.managed.persistenceRecord(cleanExit: true, exitedAt: h.clock.now))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStateStore(fileURL: directory.appendingPathComponent("state.json"))
        try store.save([record])
        let a = DisplayRulesV2Tests.Harness.a
        h.delegate.layoutBox.layout = ScreenLayout(screens: [
            ScreenInfo(id: 24, frame: a.frame, visibleFrame: a.visibleFrame, displayUUID: a.displayUUID), DisplayRulesV2Tests.Harness.b,
        ])
        h.delegate.invalidateDisplayLayout()
        let session = DockSession(delegate: h.delegate, clock: { h.clock.now })
        DockRecovery(store: store, now: { h.clock.now.addingTimeInterval(119) }).recover(
            geometry: h.delegate.geometry, resolver: { _ in [h.window] }, onRedock: { record, window in
                session.add(window: window, edge: record.edge) { managed in
                    managed.isLeftMousePressed = { false }
                    managed.setRecoveredIntent(record)
                }
            })
        await drainTasks()
        #expect(session.windows.count == 1)
        #expect(session.windows[0].ownedScreen(in: h.delegate.geometry)?.id == 24)
        #expect(h.window.frame == expected)
    }

    @Test("normal quit during a locked session performs no write and keeps a crash-recovery record")
    func lockedQuit() async throws {
        let h = await DisplayRulesV2Tests.Harness()
        let parked = h.window.frame
        let writes = h.window.positionWrites.count
        h.session.lock()
        let exited = h.session.quit()
        let record = try #require(exited[0].persistenceRecord(cleanExit: true, exitedAt: h.clock.now))
        #expect(!record.isCleanExit)
        #expect(record.parkedFrame.rect == parked)
        #expect(h.window.positionWrites.count == writes)
    }

    @Test("an offline original screen prevents upgrade redock but still places the window visibly")
    func offlineOriginalDuringUpgrade() async throws {
        let h = await DisplayRulesV2Tests.Harness()
        h.window.windowID = 7
        h.managed.restore()
        let record = try #require(h.managed.persistenceRecord(cleanExit: true, exitedAt: h.clock.now))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStateStore(fileURL: directory.appendingPathComponent("state.json"))
        try store.save([record])
        h.delegate.layoutBox.layout = ScreenLayout(screens: [DisplayRulesV2Tests.Harness.internalScreen])
        h.delegate.invalidateDisplayLayout()
        var redocked = false
        DockRecovery(store: store, now: { h.clock.now }).recover(geometry: h.delegate.geometry, resolver: { _ in [h.window] },
                                                              onRedock: { _, _ in redocked = true })
        #expect(!redocked)
        #expect(h.delegate.geometry.visibleFraction(of: h.window.frame!) == 1)
    }
}
