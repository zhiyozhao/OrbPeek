import AppKit
import CoreGraphics
import ScreenCaptureKit

// ScreenCaptureKit-based capture of the strip image. Captures a REGION OF THE
// DISPLAY (composited pixels — translucency, shadow and rounded corners all
// look exactly as the real window does on screen), unlike a window-filter
// capture which returns the raw, flattened surface. Display captures are fast
// (~50ms) and never hit the ~1s stalls window-filter captures have on parked
// windows, so every dock captures fresh.
//
// Every successful capture is cached by (windowID, edge, size). The cache is
// only a fallback for the one case where a live capture is impossible —
// re-docking a window that is parked off-screen — and for showing the strip
// instantly while the fresh capture is in flight.
@MainActor
final class SliceCapturer {
    private var shareableContent: SCShareableContent?

    private struct SliceKey: Hashable {
        let windowID: CGWindowID
        let edge: DockEdge
    }

    private var sliceCache: [SliceKey: (image: NSImage, size: CGSize)] = [:]

    // The last capture for this window/edge, only if the window still has the
    // same size (a resize makes the cached slice's proportions wrong).
    func cachedSlice(for windowID: CGWindowID, edge: DockEdge, size: CGSize) -> NSImage? {
        guard let entry = sliceCache[SliceKey(windowID: windowID, edge: edge)],
              entry.size == size else { return nil }
        return entry.image
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

    // Capture ALL FOUR edge slices of the window with a single display capture
    // of its frame region, then crop per edge. The window must be on screen.
    // Every slice is cached (keyed by edge), so a later hidden re-dock to ANY
    // edge has content. Slice choice mimics the window really sliding off the
    // edge: up -> bottom slice, down -> title bar, left -> right edge,
    // right -> left edge.
    func captureAllSlices(frame: CGRect, displayID: CGDirectDisplayID?, windowID: CGWindowID?, thickness: CGFloat) async -> [DockEdge: NSImage]? {
        guard let content = try? await contentForCaptures(),
              let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }
        let local = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
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
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else {
            Log.info("display capture \(Int(Date().timeIntervalSince(t0) * 1000))ms got=false")
            return nil
        }
        Log.info("display capture \(Int(Date().timeIntervalSince(t0) * 1000))ms got=true")
        let w = local.width
        let h = local.height
        let t = thickness
        let rects: [DockEdge: CGRect] = [
            .up: CGRect(x: 0, y: h - t, width: w, height: t),
            .down: CGRect(x: 0, y: 0, width: w, height: t),
            .left: CGRect(x: w - t, y: 0, width: t, height: h),
            .right: CGRect(x: 0, y: 0, width: t, height: h),
        ]
        let bounds = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        var out: [DockEdge: NSImage] = [:]
        for (edge, r) in rects {
            let px = CGRect(x: r.minX * scale, y: r.minY * scale,
                            width: r.width * scale, height: r.height * scale).intersection(bounds)
            guard !px.isNull, !px.isEmpty, let crop = img.cropping(to: px) else { continue }
            let image = NSImage(cgImage: crop, size: r.size)
            out[edge] = image
            if let windowID {
                if sliceCache.count > 40 { sliceCache.removeAll() }
                sliceCache[SliceKey(windowID: windowID, edge: edge)] = (image, frame.size)
            }
        }
        return out
    }

    // Cached shareable content; refreshed if it doesn't list our own app — a
    // process only appears there once it has a window, and we must be able to
    // exclude our strip panels from captures.
    private func contentForCaptures() async throws -> SCShareableContent {
        let pid = ProcessInfo.processInfo.processIdentifier
        if let shareableContent,
           shareableContent.applications.contains(where: { $0.processID == pid }) {
            return shareableContent
        }
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
