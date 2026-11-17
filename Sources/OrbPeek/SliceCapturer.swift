import AppKit
import CoreGraphics
import ScreenCaptureKit
import OrbPeekCore

enum TimeoutOutcome<T> {
    case finished(T?)
    case timedOut
}

func withTimeoutOutcome<T>(_ seconds: Double, _ work: @escaping () async -> T?) async -> TimeoutOutcome<T> {
    await withTaskGroup(of: TimeoutOutcome<T>.self) { group in
        group.addTask { .finished(await work()) }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return .timedOut
        }
        let result = await group.next() ?? .timedOut
        group.cancelAll()
        return result
    }
}

func withTimeout<T>(_ seconds: Double, _ work: @escaping () async -> T?) async -> T? {
    switch await withTimeoutOutcome(seconds, work) {
    case .finished(let value): return value
    case .timedOut: return nil
    }
}

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
private struct CaptureAttempt {
    let image: CGImage?
    let timedOut: Bool
}

@MainActor
package final class SliceCapturer: SliceCapturing {
    private var shareableContent: SCShareableContent?
    private var replaydRestartPolicy = ReplaydRestartPolicy()

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

    package func cachedImage(for windowID: CGWindowID) -> NSImage? {
        guard let entry = windowImages[windowID] else { return nil }
        return NSImage(cgImage: entry.image, size: entry.size)
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
            guard let content = try? await refreshContent(),
                  let display = content.displays.first else {
                Log.info("capture prewarm aborted: no content/display")
                return
            }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            cfg.width = 2
            cfg.height = 2
            cfg.showsCursor = false
            let t0 = Date()
            _ = await withTimeout(2.0) { try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) }
            Log.info("capture pipeline prewarmed in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
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
    // Failure recovery: replayd (SCK's daemon) can wedge — captureImage then
    // hangs forever (field-observed). The community-documented recovery is
    // restarting the daemon, so a failed/timed-out attempt kicks replayd once
    // and retries with freshly fetched content before giving up.
    package func captureWindow(frame: CGRect, displayID: CGDirectDisplayID?, windowID: CGWindowID?) async -> CGImage? {
        let t0 = Date()
        var attempt = await attemptCapture(frame: frame, displayID: displayID)
        if attempt.timedOut {
            if replaydRestartPolicy.recordTimeout(at: Date()) {
                Log.info("3 consecutive capture timeouts; restarting replayd (5-minute cooldown)")
                kickstartReplayd()
                shareableContent = nil
                try? await Task.sleep(nanoseconds: 300_000_000)
                attempt = await attemptCapture(frame: frame, displayID: displayID)
                if attempt.timedOut { _ = replaydRestartPolicy.recordTimeout(at: Date()) }
                else { replaydRestartPolicy.recordOtherResult() }
            } else {
                Log.info("capture timeout; replayd restart suppressed by threshold/cooldown")
            }
        } else {
            if attempt.image == nil { Log.info("capture failed without timeout; replayd not restarted") }
            replaydRestartPolicy.recordOtherResult()
        }
        let img = attempt.image
        Log.info("display capture \(Int(Date().timeIntervalSince(t0) * 1000))ms got=\(img != nil)")
        guard let img else { return nil }
        guard let content = shareableContent,
              let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return img }
        if let windowID, display.frame.contains(frame) {
            if windowImages.count > 8 { windowImages.removeAll() }
            windowImages[windowID] = (img, frame.size)
        }
        return img
    }

    private func attemptCapture(frame: CGRect, displayID: CGDirectDisplayID?) async -> CaptureAttempt {
        // Distinguish timeouts from ordinary failures so replayd is never
        // restarted for permission, empty-content, or unsupported-window errors.
        let contentOutcome = await withTimeoutOutcome(0.5, { try? await self.contentForCaptures() })
        switch contentOutcome {
        case .timedOut:
            return CaptureAttempt(image: nil, timedOut: true)
        case .finished(let value):
            guard let content = value,
                  let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                return CaptureAttempt(image: nil, timedOut: false)
            }
            let local = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            guard local.width > 0, local.height > 0 else { return CaptureAttempt(image: nil, timedOut: false) }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let excluding = content.applications.filter { $0.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingApplications: excluding, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = local
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(local.width * scale)
            cfg.height = Int(local.height * scale)
            cfg.showsCursor = false
            switch await withTimeoutOutcome(0.3, { try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) }) {
            case .timedOut: return CaptureAttempt(image: nil, timedOut: true)
            case .finished(let image): return CaptureAttempt(image: image, timedOut: false)
            }
        }
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
