import CoreGraphics
import Foundation
import Testing
@testable import OrbPeek

private func testImage() -> CGImage {
    CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

private actor CaptureFixture {
    enum Mode { case success, imageError, contentError, missing, imageHang, contentHang }
    var modes: [Mode]
    var loads = 0
    var captures = 0
    var locals: [CGRect] = []
    private var nextCaptureFails = false
    let blocked = SuspendedCapture()
    private var started: CheckedContinuation<Void, Never>?
    init(_ modes: [Mode]) { self.modes = modes }
    func load() async throws -> CaptureContent? {
        let mode = modes[min(loads, modes.count - 1)]
        loads += 1
        if mode == .contentError { throw NSError(domain: "FakeContent", code: 17) }
        if mode == .contentHang { _ = await blocked.wait() }
        return CaptureContent(displays: [CaptureDisplay(id: mode == .missing ? 99 : 2,
            frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)) { local in
                try await self.capture(mode, local: local)
            }], containsOwnApplication: true)
    }
    private func capture(_ mode: Mode, local: CGRect) async throws -> CGImage? {
        captures += 1; locals.append(local)
        started?.resume(); started = nil
        if nextCaptureFails {
            nextCaptureFails = false
            throw NSError(domain: "FakeImage", code: 23)
        }
        if mode == .imageError { throw NSError(domain: "FakeImage", code: 23) }
        if mode == .imageHang { _ = await blocked.wait() }
        return testImage()
    }
    func waitUntilCaptureStarts() async {
        if captures > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func failNextCapture() { nextCaptureFails = true }
}

@Suite("fresh exact-display screenshot recovery")
@MainActor
struct CapturePipelineTests {
    let frame = CGRect(x: 2000, y: 120, width: 300, height: 600)

    @Test("a cached failure or content error retries with new content and logs its error", arguments: [false, true])
    func retry(contentError: Bool) async {
        let fake = CaptureFixture([contentError ? .contentError : .success, .success])
        var logs: [String] = []
        var restarts = 0
        let pipeline = CapturePipeline(load: { try await fake.load() }, restart: { restarts += 1 }, log: { logs.append($0) })
        if !contentError {
            #expect(await pipeline.capture(frame: frame, displayID: 2) != nil)
            await fake.failNextCapture() // the previously cached content is now stale
        }
        #expect(await pipeline.capture(frame: frame, displayID: 2) != nil)
        #expect(await fake.loads == 2)
        #expect(logs.contains { $0.contains(contentError ? "FakeContent code=17" : "FakeImage code=23") })
        #expect(restarts == 0)
        if !contentError { #expect(await fake.locals.last == CGRect(x: 80, y: 120, width: 300, height: 600)) }
    }

    @Test("every invalidation forces a refetch even when our PID is cached", arguments:
        ["display begin", "display end", "screen parameters", "wake", "unlock", "session active", "screen saver"])
    func invalidation(reason: String) async {
        let fake = CaptureFixture([.success])
        let pipeline = CapturePipeline(load: { try await fake.load() }, restart: {}, log: { _ in })
        #expect(await pipeline.capture(frame: frame, displayID: 2) != nil)
        #expect(await pipeline.capture(frame: frame, displayID: 2) != nil)
        #expect(await fake.loads == 1)
        pipeline.invalidate(reason: reason)
        #expect(await pipeline.capture(frame: frame, displayID: 2) != nil)
        #expect(await fake.loads == 2)
    }

    @Test("a missing or unspecified display never captures the first other display", arguments: [false, true])
    func noWrongScreen(nilID: Bool) async {
        let fake = CaptureFixture([.missing])
        var logs: [String] = []
        let pipeline = CapturePipeline(load: { try await fake.load() }, restart: {}, log: { logs.append($0) })
        #expect(await pipeline.capture(frame: frame, displayID: nilID ? nil : 2) == nil)
        #expect(await fake.loads == 2)
        #expect(await fake.captures == 0)
        #expect(logs.contains { $0.contains("no fallback") })
    }

    @Test("hung image or enumeration returns on deadline and late results cannot poison the cache", arguments: [false, true])
    func bounded(contentHang: Bool) async {
        let fake = CaptureFixture([contentHang ? .contentHang : .imageHang, .success])
        let blocked = fake.blocked
        var restarts = 0
        let pipeline = CapturePipeline(load: { try await fake.load() }, restart: { restarts += 1 }, log: { _ in },
            contentTimeout: 0.02, imageTimeout: 0.02)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { blocked.release() }
        let started = ContinuousClock.now
        #expect(await pipeline.capture(frame: frame, displayID: 2) != nil)
        #expect(!blocked.wasReleased)
        #expect(ContinuousClock.now - started < .milliseconds(800))
        blocked.release()
        #expect(await pipeline.capture(frame: frame, displayID: 2) != nil)
        #expect(await fake.loads == 2)
        #expect(restarts == 0) // A successful fresh retry breaks the streak.
    }

    @Test("three logical capture timeouts restart once, cooldown and ordinary errors remain safe")
    func timeoutPolicy() async {
        let fake = CaptureFixture([.imageHang])
        let blocked = fake.blocked
        defer { blocked.release() }
        var now = Date(timeIntervalSince1970: 1000)
        var restarts = 0
        let pipeline = CapturePipeline(load: { try await fake.load() }, restart: { restarts += 1 }, log: { _ in },
            clock: { now }, contentTimeout: 0.02, imageTimeout: 0.01)
        for _ in 0..<2 { #expect(await pipeline.capture(frame: frame, displayID: 2) == nil) }
        #expect(restarts == 0)
        #expect(await pipeline.capture(frame: frame, displayID: 2) == nil)
        #expect(restarts == 1)
        for _ in 0..<3 { _ = await pipeline.capture(frame: frame, displayID: 2) }
        #expect(restarts == 1)
        now += 301
        for _ in 0..<3 { _ = await pipeline.capture(frame: frame, displayID: 2) }
        #expect(restarts == 2)
    }

    @Test("outstanding system requests have a finite budget")
    func requestBudget() throws {
        let budget = CaptureRequestBudget(limit: 2)
        try budget.acquire(); try budget.acquire()
        #expect(throws: (any Error).self) { try budget.acquire() }
        budget.release()
        try budget.acquire()
        budget.release(); budget.release()
    }

    @Test("an invalidation during capture discards the old image before caching or returning")
    func invalidatedInFlight() async {
        let fake = CaptureFixture([.imageHang, .success])
        let pipeline = CapturePipeline(load: { try await fake.load() }, restart: {}, log: { _ in })
        let first = Task { await pipeline.capture(frame: frame, displayID: 2) }
        await fake.waitUntilCaptureStarts()
        pipeline.invalidate(reason: "display replaced")
        fake.blocked.release()
        #expect(await first.value == nil)
        #expect(await pipeline.capture(frame: frame, displayID: 2) != nil)
        #expect(await fake.loads == 2)
    }
}
