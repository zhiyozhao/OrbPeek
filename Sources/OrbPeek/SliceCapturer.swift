import AppKit
import CoreGraphics
import ScreenCaptureKit
import OrbPeekCore

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
package final class SliceCapturer: SliceCapturing {
    private lazy var pipeline = CapturePipeline(load: { try await ScreenCaptureService.content() },
        restart: { [weak self] in self?.kickstartReplayd() }, log: Log.info)

    package func invalidateContent(reason: String) { pipeline.invalidate(reason: reason) }

    package func canCaptureWindow(frame: CGRect, windowID: CGWindowID?) -> Bool {
        guard let windowID else { return false }
        return CaptureVisibility.current(frame: frame, target: windowID)
    }

    // Full-window captures keyed by CGWindowID. One image serves all four
    // edges and any strip thickness — slices are cropped on read, so changing
    // sliverPx in settings re-crops instantly without a new capture. (The
    // capture itself already photographs the whole window frame, so caching
    // the full image costs nothing but a few MB of memory.)
    private var windowImages: [CGWindowID: (image: CGImage, size: CGSize)] = [:]

    // The cached slice for a window/edge at the given thickness, only if the
    // window still has the same size (a resize makes the capture stale).
    package func cachedSlice(for windowID: CGWindowID, edge: DockEdge, size: CGSize, thickness: CGFloat) -> NSImage? {
        guard let entry = windowImages[windowID], entry.size == size else { return nil }
        return slice(from: entry.image, edge: edge, windowSize: size, thickness: thickness)
    }

    // Crop the slice for an edge out of a full-window image. Slice choice
    // mimics the window really sliding off the edge: up -> bottom slice,
    // down -> title bar, left -> right edge, right -> left edge.
    package func slice(from image: CGImage, edge: DockEdge, windowSize: CGSize, thickness: CGFloat) -> NSImage? {
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
    // one-time enumeration/setup cost. Bounded and logged: captureImage can
    // hang forever when replayd (SCK's daemon) is wedged, and that must never
    // be silent.
    func prewarm() {
        Task {
            let t0 = Date()
            let id = CGMainDisplayID()
            let frame = CGRect(origin: CGDisplayBounds(id).origin, size: CGSize(width: 1, height: 1))
            let result = await pipeline.capture(frame: frame, displayID: id, prewarm: true)
            Log.info("capture pipeline prewarmed in \(Int(Date().timeIntervalSince(t0) * 1000))ms capture got=\(result != nil)")
        }
    }

    // Find the CGWindowID for a window by owner PID and frame.
    package func windowID(for pid: pid_t, matching frame: CGRect) -> CGWindowID? {
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
    package func windowExists(_ id: CGWindowID) -> Bool {
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
    //
    // All failures retry once with fresh content and the exact display ID.
    // Deadlines return without joining an uncooperative ScreenCaptureKit call.
    package func captureWindow(frame: CGRect, displayID: CGDirectDisplayID?, windowID: CGWindowID?) async -> CGImage? {
        guard canCaptureWindow(frame: frame, windowID: windowID) else {
            Log.info("composite capture deferred: obscured/moved/missing window wid=\(windowID.map(String.init) ?? "nil")")
            return nil
        }
        let t0 = Date()
        let result = await pipeline.capture(frame: frame, displayID: displayID)
        let accepted = result != nil && canCaptureWindow(frame: frame, windowID: windowID)
        Log.info("display capture \(Int(Date().timeIntervalSince(t0) * 1000))ms got=\(accepted) display=\(displayID.map(String.init) ?? "nil") wid=\(windowID.map(String.init) ?? "nil")")
        guard let result else { return nil }
        guard accepted else {
            Log.info("composite capture discarded: visibility changed wid=\(windowID.map(String.init) ?? "nil")")
            return nil
        }
        if let windowID, result.displayFrame.contains(frame) {
            if windowImages.count > 8 { windowImages.removeAll() }
            windowImages[windowID] = (result.image, frame.size)
        }
        return result.image
    }

    // Restart SCK's daemon — the documented fix for wedged captures
    // (github.com/nonstrict-hq/SCShareableContent-hangs-sample). Note:
    // `launchctl kickstart` is SIP-blocked on modern macOS, but a same-UID
    // SIGTERM via killall is allowed and launchd restarts the daemon.
    private func kickstartReplayd() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["replayd"]
        try? p.run() // fire and forget — never block on the daemon's lifecycle
    }

}
