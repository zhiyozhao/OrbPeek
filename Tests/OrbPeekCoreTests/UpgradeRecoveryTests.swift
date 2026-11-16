import Foundation
import Testing
@testable import OrbPeekCore

@Suite("normal-exit upgrade recovery")
@MainActor
struct UpgradeRecoveryTests {
    @Test("re-docks a matched window within two minutes")
    func recentExitRedocks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockStateStore(fileURL: directory.appendingPathComponent("docked-windows.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = await makeDockedFixture(layout: testLayout)
        var record = try #require(fixture.managed.persistenceRecord())
        let exitedAt = fixture.clock.now
        record.cleanExit = true
        record.exitedAt = exitedAt
        fixture.managed.restore()
        try store.save([record])
        var redocked: [DockEdge] = []

        DockRecovery(store: store, now: { exitedAt.addingTimeInterval(119) }).recover(
            geometry: fixture.delegate.geometry,
            resolver: { _ in [fixture.window] },
            onRedock: { record, _ in redocked.append(record.edge) }
        )
        #expect(redocked == [.down])
        #expect(try store.load().isEmpty)
    }

    @Test("discards an exit record older than two minutes")
    func expiredExitIsSkipped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockStateStore(fileURL: directory.appendingPathComponent("docked-windows.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = await makeDockedFixture(layout: testLayout)
        var record = try #require(fixture.managed.persistenceRecord())
        let exitedAt = fixture.clock.now
        record.cleanExit = true
        record.exitedAt = exitedAt
        fixture.managed.restore()
        try store.save([record])
        var redocked = false

        DockRecovery(store: store, now: { exitedAt.addingTimeInterval(121) }).recover(
            geometry: fixture.delegate.geometry,
            resolver: { _ in [fixture.window] },
            onRedock: { _, _ in redocked = true }
        )
        #expect(!redocked)
        #expect(try store.load().isEmpty)
    }
}
