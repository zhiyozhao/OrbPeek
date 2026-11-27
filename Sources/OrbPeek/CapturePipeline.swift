import CoreGraphics
import Foundation
import OrbPeekCore

// Immutable adapters keep SCK objects out of the orchestration and its tests.
// The live implementation captures composited display regions, never windows.
struct CaptureDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect
    let capture: @Sendable (CGRect) async throws -> CGImage?
}
struct CaptureContent {
    let displays: [CaptureDisplay]
    let containsOwnApplication: Bool
}
struct CaptureResult {
    let image: CGImage
    let displayFrame: CGRect
}

@MainActor
final class CapturePipeline {
    private var content: CaptureContent?
    private var generation: UInt64 = 0
    private var policy = ReplaydRestartPolicy()
    private let load: @Sendable () async throws -> CaptureContent?
    private let restart: () -> Void
    private let log: (String) -> Void
    private let clock: () -> Date
    private let contentTimeout: Double
    private let imageTimeout: Double

    init(load: @escaping @Sendable () async throws -> CaptureContent?,
         restart: @escaping () -> Void, log: @escaping (String) -> Void,
         clock: @escaping () -> Date = Date.init,
         contentTimeout: Double = 0.5, imageTimeout: Double = 0.3) {
        self.load = load; self.restart = restart; self.log = log; self.clock = clock
        self.contentTimeout = contentTimeout; self.imageTimeout = imageTimeout
    }

    func invalidate(reason: String) {
        generation &+= 1
        content = nil
        log("SC content invalidated: \(reason)")
    }

    private func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) code=\(e.code) \(e.localizedDescription)"
    }

    private func contentForCapture() async -> TimeoutOutcome<CaptureContent> {
        if let content, content.containsOwnApplication { return .finished(content) }
        let requestedGeneration = generation
        let started = clock()
        let outcome = await withTimeoutOutcome(contentTimeout, load)
        // A timed-out/invalidated enumeration must never repopulate the cache.
        guard requestedGeneration == generation else {
            log("SC refetch discarded: layout/session changed while enumerating")
            return .cancelled
        }
        switch outcome {
        case .finished(let value):
            content = value
            log("SC refetch took \(Int(clock().timeIntervalSince(started) * 1000))ms displays=\(value?.displays.map(\.id) ?? [])")
        case .failed(let error): log("SCShareableContent error: \(describe(error))")
        case .timedOut: log("SCShareableContent timeout after \(contentTimeout)s")
        case .cancelled: break
        }
        return outcome
    }

    private struct Attempt {
        var result: CaptureResult?
        var timedOut = false
        var cancelled = false
    }

    private func attempt(frame: CGRect, displayID: CGDirectDisplayID?, imageTimeout: Double) async -> Attempt {
        let requestedGeneration = generation
        let loaded = await contentForCapture()
        guard !Task.isCancelled else { return Attempt(cancelled: true) }
        switch loaded {
        case .timedOut: return Attempt(timedOut: true)
        case .cancelled: return Attempt(cancelled: true)
        case .failed: return Attempt()
        case .finished(let content):
            guard let displayID, let display = content?.displays.first(where: { $0.id == displayID }) else {
                log("capture display missing requested=\(displayID.map(String.init) ?? "nil") available=\(content?.displays.map(\.id) ?? []); no fallback")
                return Attempt()
            }
            guard frame.width > 0, frame.height > 0 else { return Attempt() }
            let local = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let outcome = await withTimeoutOutcome(imageTimeout) { try await display.capture(local) }
            guard !Task.isCancelled, requestedGeneration == generation else {
                log("capture discarded: cancelled or layout/session changed")
                return Attempt(cancelled: true)
            }
            switch outcome {
            case .finished(let image):
                return Attempt(result: image.map { CaptureResult(image: $0, displayFrame: display.frame) })
            case .failed(let error):
                log("SCScreenshotManager error display=\(displayID): \(describe(error))")
                return Attempt()
            case .timedOut:
                log("SCScreenshotManager timeout display=\(displayID) after \(imageTimeout)s")
                return Attempt(timedOut: true)
            case .cancelled: return Attempt(cancelled: true)
            }
        }
    }

    // Count once per logical capture, not twice for the fresh-content retry.
    // A recovered request/ordinary error breaks the consecutive-timeout streak.
    func capture(frame: CGRect, displayID: CGDirectDisplayID?, prewarm: Bool = false) async -> CaptureResult? {
        var last = await attempt(frame: frame, displayID: displayID, imageTimeout: prewarm ? 2 : imageTimeout)
        guard !last.cancelled else { return nil }
        if last.result == nil {
            invalidate(reason: "capture failed; retry once with fresh content")
            last = await attempt(frame: frame, displayID: displayID, imageTimeout: prewarm ? 2 : imageTimeout)
        }
        guard !last.cancelled else { return nil }
        if !prewarm {
            if last.timedOut {
                if policy.recordTimeout(at: clock()) {
                    log("3 consecutive capture timeouts; restarting replayd (5-minute cooldown)")
                    restart()
                    invalidate(reason: "replayd restarted")
                } else { log("capture timeout; replayd restart suppressed by threshold/cooldown") }
            } else {
                policy.recordOtherResult()
                if last.result == nil { log("capture failed without timeout; replayd not restarted") }
            }
        }
        return last.result
    }
}
