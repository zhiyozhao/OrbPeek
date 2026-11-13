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
            [fixture.window]
        }

        #expect(fixture.window.storedFrame == CGRect(x: 300, y: 200, width: 700, height: 500))
        #expect(try store.load().isEmpty)
    }

    @Test("changed title still recovers a mostly off-screen window")
    func changedTitleFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockStateStore(fileURL: directory.appendingPathComponent("docked-windows.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = FakeWindow(frame: CGRect(x: -699, y: 580, width: 700, height: 500))
        window.title = "New document title"
        let record = DockedWindowRecord(
            processID: 42, bundleIdentifier: "fake.editor", title: "Old document title", windowID: 7,
            restoreFrame: CGRect(x: 300, y: 200, width: 700, height: 500),
            parkedFrame: window.storedFrame!, dockScreenID: 1, edge: .down
        )
        try store.save([record])
        DockRecovery(store: store).recover(geometry: WindowGeometry(layout: testLayout)) { _ in [window] }
        let geometry = WindowGeometry(layout: testLayout)
        #expect(geometry.quartzVisibleFrame(of: testPrimary).contains(window.storedFrame!))
    }

    @Test("untitled multi-window app recovers every mostly off-screen window")
    func untitledMultipleWindows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DockStateStore(fileURL: directory.appendingPathComponent("docked-windows.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FakeWindow(frame: CGRect(x: -699, y: 200, width: 700, height: 500))
        let second = FakeWindow(frame: CGRect(x: 4000, y: 100, width: 700, height: 500))
        first.title = nil
        second.title = nil
        let record = DockedWindowRecord(
            processID: 42, bundleIdentifier: "fake.browser", title: nil, windowID: nil,
            restoreFrame: CGRect(x: 300, y: 200, width: 700, height: 500),
            parkedFrame: first.storedFrame!, dockScreenID: 1, edge: .down
        )
        try store.save([record])
        DockRecovery(store: store).recover(geometry: WindowGeometry(layout: testLayout)) { _ in [first, second] }
        let geometry = WindowGeometry(layout: testLayout)
        #expect(geometry.quartzVisibleFrame(of: testPrimary).contains(first.storedFrame!))
        #expect(geometry.quartzVisibleFrame(of: testSecondary).contains(second.storedFrame!))
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
        DockRecovery(store: store).recover(geometry: WindowGeometry(layout: testLayout)) { _ in [] }
        #expect(try store.load().isEmpty)
    }
}
