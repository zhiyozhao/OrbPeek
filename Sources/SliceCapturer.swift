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

    // Full-window captures keyed by CGWindowID. One image serves all four
    // edges and any strip thickness — slices are cropped on read, so changing
    // sliverPx in settings re-crops instantly without a new capture. (The
    // capture itself already photographs the whole window frame, so caching
    // the full image costs nothing but a few MB of memory.)
    private var windowImages: [CGWindowID: (image: CGImage, size: CGSize)] = [:]

    // The cached slice for a window/edge at the given thickness, only if the
    // window still has the same size (a resize makes the capture stale).
    func cachedSlice(for windowID: CGWindowID, edge: DockEdge, size: CGSize, thickness: CGFloat) -> NSImage? {
        guard let entry = windowImages[windowID], entry.size == size else { return nil }
        return slice(from: entry.image, edge: edge, windowSize: size, thickness: thickness)
    }

    // Crop the slice for an edge out of a full-window image. Slice choice
    // mimics the window really sliding off the edge: up -> bottom slice,
    // down -> title bar, left -> right edge, right -> left edge.
    func slice(from image: CGImage, edge: DockEdge, windowSize: CGSize, thickness: CGFloat) -> NSImage? {
        let scale = CGFloat(image.width) / max(windowSize.width, 1)
        let w = windowSize.width
        let h = windowSize.height
        let t = thickness
        let r: CGRect
        switch edge {
        case .up: r = CGRect(x: 0, y: h - t, width: w, height: t)
        case .down: r = CGRect(x: 0, y: 0, width: w, height: t)
        case .left: r = CGRect(x: w - t, y: 0, width: t, height: h)
        case .right: r = CGRect(x: 0, y: 0, width: t, height: h)
        }
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !px.isNull, !px.isEmpty, let crop = image.cropping(to: px) else { return nil }
        return NSImage(cgImage: crop, size: r.size)
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

    // Whether a window still exists. CGWindowList is window-server level, so
    // it answers even when the owning app is hung and AX reads time out —
    // used to tell "window closed" apart from "app beachballing" before
    // dropping a managed window.
    func windowExists(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int).map { CGWindowID($0) } == id }
    }

    // Drop the cached capture for a window whose dock was released — its
    // content can change while unmanaged, and there's no reason to keep a
    // screenshot of an unmanaged window around.
    func evict(_ id: CGWindowID) {
        windowImages.removeValue(forKey: id)
    }

    // Composited capture of the window's frame region (quartz coordinates).
    // The window must be on screen. Our own windows (the strip) are excluded
    // so they can't contaminate the image. A successful capture is cached in
    // full when `windowID` is given.
    func captureWindow(frame: CGRect, displayID: CGDirectDisplayID?, windowID: CGWindowID?) async -> CGImage? {
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
        let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        Log.info("display capture \(Int(Date().timeIntervalSince(t0) * 1000))ms got=\(img != nil)")
        guard let img else { return nil }
        // Cache only fully on-screen captures — off-screen parts of the window
        // render blank and would poison the cache.
        if let windowID, display.frame.contains(frame) {
            if windowImages.count > 8 { windowImages.removeAll() }
            windowImages[windowID] = (img, frame.size)
        }
        return img
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
