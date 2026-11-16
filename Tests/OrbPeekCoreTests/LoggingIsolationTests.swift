import Foundation
import Testing
@testable import OrbPeekCore

@Suite("test logging isolation")
@MainActor
struct LoggingIsolationTests {
    @Test("default Core loggers never touch the real OrbPeek log")
    func defaultsDoNotWriteUserLog() async {
        let logURL = URL(fileURLWithPath: Log.path)
        let before = try? Data(contentsOf: logURL)
        let delegate = FakeDelegate(layout: testLayout)
        let session = DockSession(delegate: delegate)
        session.add(window: FakeWindow(frame: CGRect(x: 100, y: 100, width: 500, height: 400)), edge: .down)
        await drainTasks()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockStateStore(fileURL: directory.appendingPathComponent("state.json"))
        DockRecovery(store: store).recover(geometry: delegate.geometry) { _ in [] }
        let after = try? Data(contentsOf: logURL)
        #expect(after == before)
    }
}
