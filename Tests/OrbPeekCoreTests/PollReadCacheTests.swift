import AppKit
import Testing
@testable import OrbPeekCore

@Suite("poll read scope")
@MainActor
struct PollReadCacheTests {
    @Test("read coalescing preserves the 30Hz hover dwell and immediate slam", arguments: [false, true])
    func hoverLatency(slam: Bool) async {
        let f = await makeDockedFixture(layout: testLayout)
        f.window.cacheReads = true
        let session = DockSession(delegate: f.delegate, clock: { f.clock.now })
        session.adopt(f.managed)
        let screen = f.managed.dockScreen(in: f.delegate.geometry)!
        let rect = f.delegate.geometry.sliverRect(edge: .down, size: f.window.frame!.size,
            perp: f.managed.perp, screen: screen, thickness: f.delegate.config.sliverPx)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        if slam {
            session.poll(mouseQ: point, mouseVelocity: CGPoint(x: 0, y: 2000))
        } else {
            for _ in 0..<5 {
                session.poll(mouseQ: point)
                #expect(f.managed.phase == .docked)
                f.clock.advance(1.0 / 30)
            }
            session.poll(mouseQ: point)
        }
        #expect(f.managed.phase == .peeked)
        #expect(session.unreachableWindows().isEmpty)
        await drainTasks()
    }

    @Test("reads coalesce including nil, writes invalidate and no value survives a poll")
    func lifetime() {
        let cache = PollReadCache<Int?>()
        var value: Int? = nil
        var reads = 0
        func read() -> Int? { cache.read { reads += 1; return value } }
        #expect(read() == nil); #expect(read() == nil); #expect(reads == 2)
        cache.begin()
        #expect(read() == nil); #expect(read() == nil); #expect(reads == 3)
        value = 7; cache.invalidate()
        #expect(read() == 7); #expect(read() == 7); #expect(reads == 4)
        cache.begin(); #expect(read() == 7); cache.end()
        #expect(reads == 4)
        cache.end(); value = 8
        cache.begin(); #expect(read() == 8); #expect(reads == 5); cache.end()
        value = 9; #expect(read() == 9); #expect(reads == 6)
    }

    @Test("session scopes duplicate reads but observes the very next poll's external move")
    func session() async {
        let f = await makeDockedFixture(layout: testLayout)
        let session = DockSession(delegate: f.delegate, clock: { f.clock.now })
        session.adopt(f.managed)
        f.window.cacheReads = true
        let reads = f.window.frameReadCount
        session.poll(mouseQ: CGPoint(x: -9999, y: -9999)) { _ in
            _ = f.window.frame; _ = f.window.frame; return false
        }
        #expect(f.window.frameReadCount == reads + 1)
        let old = f.window.storedFrame!
        f.window.storedFrame!.origin.x += 3
        session.poll(mouseQ: CGPoint(x: -9999, y: -9999))
        #expect(f.window.storedFrame == old) // Drift is re-anchored immediately.
        // Reads outside poll cannot reuse a snapshot, including failed writes.
        f.window.rejectWrites = true
        f.window.beginPoll(); _ = f.window.frame
        let count = f.window.frameReadCount
        f.window.position = .zero; _ = f.window.frame
        #expect(f.window.frameReadCount == count + 1)
        f.window.endPoll()
    }
}
