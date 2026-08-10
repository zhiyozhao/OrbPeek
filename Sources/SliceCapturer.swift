import AppKit
import CoreGraphics
import ScreenCaptureKit

// ScreenCaptureKit-based capture of the strip image. Captures a REGION OF THE
// DISPLAY (composited pixels — translucency, shadow and rounded corners all
// look exactly as the real window does on screen), unlike a window-filter
// capture which returns the raw, flattened surface. Display captures also
// never hit the ~1s stalls that window-filter captures do on parked windows.
@MainActor
final class SliceCapturer {
    private var shareableContent: SCShareableContent?
    // Last captured slice per window AND edge — up/down show the title bar,
    // left/right the adjacent vertical edge. Keyed by ID (not ManagedWindow)
    // so the cache survives cancel/re-dock.
    private struct SliceKey: Hashable {
        let windowID: CGWindowID
        let edge: DockEdge
    }

    private var sliceCache: [SliceKey: NSImage] = [:]

    func cachedSlice(for windowID: CGWindowID, edge: DockEdge) -> NSImage? {
        sliceCache[SliceKey(windowID: windowID, edge: edge)]
    }

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

    // Find the CGWindowID for a window by owner PID and frame.
    func windowID(for pid: pid_t, matching frame: CGRect) -> CGWindowID? {
        let t0 = Date()
        defer { Log.info("windowID lookup \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid) else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let bx = b["X"] as? Double, let by = b["Y"] as? Double,
                  let bw = b["Width"] as? Double, let bh = b["Height"] as? Double else { continue }
            if abs(bx - frame.minX) < 5 && abs(by - frame.minY) < 5
                && abs(bw - frame.width) < 5 && abs(bh - frame.height) < 5 {
                return CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0)
            }
        }
        return nil
    }

    // Composited capture of a screen region (quartz coordinates). Must be
    // called while the window is still on screen at that region. Our own
    // windows (the strip) are excluded so they can't contaminate the image.
    func captureSlice(screenRect: CGRect, displayID: CGDirectDisplayID?, windowID: CGWindowID, edge: DockEdge) async -> NSImage? {
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
        let result = NSImage(cgImage: img, size: screenRect.size)
        if sliceCache.count > 20 { sliceCache.removeAll() }
        sliceCache[SliceKey(windowID: windowID, edge: edge)] = result
        return result
    }

    // Cached shareable content; refreshed if never fetched (display/app lists
    // change rarely, and a stale list only costs us the self-exclusion).
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
