import CoreGraphics
import Foundation
import Testing
@testable import OrbPeekCore

@Suite("crash recovery journal")
@MainActor
struct CrashRecoveryTests {
    @Test("SIGKILL leaves a journal; next launch restores the still-parked fake window")
    func killedProcessRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("docked-windows.json")
        let store = DockStateStore(fileURL: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = await makeDockedFixture(layout: testLayout)
        let record = try #require(fixture.managed.persistenceRecord())
        #expect(fixture.delegate.stateChangeCount >= 2) // docking intent + completed parking
        try store.save([record])
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Simulate OrbPeek dying: no restore(), no clear(), window remains parked.
        #expect(fixture.window.storedFrame?.minX == -699)
        DockRecovery(store: store).recover(geometry: WindowGeometry(layout: testLayout)) { _ in
            fixture.window
        }

        #expect(fixture.window.storedFrame == CGRect(x: 300, y: 200, width: 700, height: 500))
        #expect(try store.load().isEmpty)
    }

    @Test("missing window is skipped and its stale journal is cleared")
    func missingWindow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockStateStore(fileURL: directory.appendingPathComponent("docked-windows.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = DockedWindowRecord(
            processID: 999, bundleIdentifier: "gone.app", title: "Changed title", windowID: nil,
            restoreFrame: CGRect(x: 100, y: 100, width: 500, height: 400),
            parkedFrame: CGRect(x: -499, y: 100, width: 500, height: 400),
            dockScreenID: 1, edge: .left
        )
        try store.save([record])
        DockRecovery(store: store).recover(geometry: WindowGeometry(layout: testLayout)) { _ in nil }
        #expect(try store.load().isEmpty)
    }
}
