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
        fixture.window.windowID = 7
        fixture.managed.restore()
        let exitedAt = fixture.clock.now
        let record = try #require(fixture.managed.persistenceRecord(cleanExit: true, exitedAt: exitedAt))
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

    @Test("moved or retitled window is not re-docked")
    func movedWindowDoesNotRedock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockStateStore(fileURL: directory.appendingPathComponent("docked-windows.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.window.windowID = 7
        fixture.managed.restore()
        var record = try #require(fixture.managed.persistenceRecord(cleanExit: true, exitedAt: fixture.clock.now))
        record.exitedAt = fixture.clock.now
        try store.save([record])
        fixture.window.storedFrame = CGRect(x: 1000, y: 600, width: 700, height: 500)
        fixture.window.title = "Changed title"
        var redocked = false
        DockRecovery(store: store, now: { fixture.clock.now }).recover(geometry: fixture.delegate.geometry, resolver: { _ in [fixture.window] },
                                          onRedock: { _, _ in redocked = true })
        #expect(!redocked)
    }

    @Test("one window can be selected by only one record")
    func duplicateRecordsSelectOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockStateStore(fileURL: directory.appendingPathComponent("docked-windows.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.window.windowID = 7
        fixture.managed.restore()
        let record = try #require(fixture.managed.persistenceRecord(cleanExit: true, exitedAt: fixture.clock.now))
        try store.save([record, record])
        var picks = 0
        DockRecovery(store: store, now: { fixture.clock.now }).recover(geometry: fixture.delegate.geometry, resolver: { _ in [fixture.window] },
                                          onRedock: { _, _ in picks += 1 })
        #expect(picks == 1)
    }

    @Test("a restarted app process is not a clean-exit identity match")
    func restartedProcessDoesNotRedock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockStateStore(fileURL: directory.appendingPathComponent("docked-windows.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = await makeDockedFixture(layout: testLayout)
        fixture.managed.restore()
        let record = try #require(fixture.managed.persistenceRecord(cleanExit: true, exitedAt: fixture.clock.now))
        try store.save([record])
        fixture.window.pid = 999
        var redocked = false
        DockRecovery(store: store, now: { fixture.clock.now }).recover(geometry: fixture.delegate.geometry, resolver: { _ in [fixture.window] },
                                          onRedock: { _, _ in redocked = true })
        #expect(!redocked)
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
