import AppKit
import CoreGraphics
import ScreenCaptureKit

// ScreenCaptureKit-based capture of the strip image. Captures a REGION OF THE
// DISPLAY (composited pixels — translucency, shadow and rounded corners all
// look exactly as the real window does on screen), unlike a window-filter
// capture which returns the raw, flattened surface. Display captures are fast
// (~50ms) and never hit the ~1s stalls window-filter captures have on parked
// windows, so there's no caching — every dock captures fresh.
@MainActor
final class SliceCapturer {
    private var shareableContent: SCShareableContent?

    // Warm the capture pipeline at launch so the first capture doesn't pay the
    // one-time enumeration/setup cost.
    func prewarm() {
        Task {
            guard let content = try? await refreshContent(),
                  let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            cfg.width = 2
            cfg.height = 2
            cfg.showsCursor = false
            let t0 = Date()
            _ = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            Log.info("capture pipeline prewarmed in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        }
    }

    // Composited capture of a screen region (quartz coordinates). Must be
    // called while the window is still on screen at that region. Our own
    // windows (the strip) are excluded so they can't contaminate the image.
    func captureSlice(screenRect: CGRect, displayID: CGDirectDisplayID?) async -> NSImage? {
        guard let content = try? await contentForCaptures(),
              let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }
        let local = screenRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        guard local.width > 0, local.height > 0 else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluding = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: excluding, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = local
        let scale = CGFloat(filter.pointPixelScale)
        cfg.width = Int(local.width * scale)
        cfg.height = Int(local.height * scale)
        cfg.showsCursor = false
        let t0 = Date()
        let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        Log.info("display capture \(Int(Date().timeIntervalSince(t0) * 1000))ms got=\(img != nil)")
        guard let img else { return nil }
        return NSImage(cgImage: img, size: screenRect.size)
    }

    // Cached shareable content; refreshed if never fetched (the display/app
    // lists change rarely, and staleness only costs us the self-exclusion).
    private func contentForCaptures() async throws -> SCShareableContent {
        if let shareableContent { return shareableContent }
        return try await refreshContent()
    }

    private func refreshContent() async throws -> SCShareableContent {
        let t1 = Date()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        shareableContent = content
        Log.info("SC refetch took \(Int(Date().timeIntervalSince(t1) * 1000))ms")
        return content
    }
}
