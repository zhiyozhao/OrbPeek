import AppKit
import CoreGraphics
import ScreenCaptureKit

// ScreenCaptureKit-based capture of a window's edge slice, with a cached
// SCShareableContent so we don't re-enumerate all windows on every capture.
@MainActor
final class SliceCapturer {
    private var shareableContent: SCShareableContent?

    // Warm the capture pipeline at launch so the first fake-strip capture
    // doesn't pay the one-time enumeration/setup cost. The tiny capture is
    // needed too: SCScreenshotManager.captureImage has its own ~130ms first-
    // call pipeline setup that SCShareableContent prewarming alone doesn't cover.
    func prewarm() {
        Task {
            guard let content = try? await refreshContent() else { return }
            guard let win = content.windows.first(where: {
                $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
            }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: win)
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

    // Capture a thin slice of the window along `edge` (crops via the filter's
    // sourceRect so only the slice is captured — fast).
    func captureSlice(of windowID: CGWindowID, frame: CGRect, edge: DockEdge, sliceThickness: CGFloat) async -> NSImage? {
        guard windowID != 0, frame.width > 0 else { return nil }
        let t0 = Date()
        do {
            guard let win = try await window(withID: windowID, matching: frame) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let sliceRect: CGRect
            switch edge {
            case .up:
                sliceRect = CGRect(x: 0, y: frame.height - sliceThickness, width: frame.width, height: sliceThickness)
            case .down:
                sliceRect = CGRect(x: 0, y: 0, width: frame.width, height: sliceThickness)
            default:
                return nil
            }
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = sliceRect
            cfg.width = Int(sliceRect.width * 2)
            cfg.height = Int(sliceRect.height * 2)
            cfg.showsCursor = false
            let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            Log.info("captureImage took \(Int(Date().timeIntervalSince(t0) * 1000))ms, got=\(img != nil)")
            guard let img else { return nil }
            return NSImage(cgImage: img, size: NSSize(width: sliceRect.width, height: sliceRect.height))
        } catch {
            return nil
        }
    }

    // Map a window ID + frame to an SCWindow, refreshing the cached content if
    // the frame no longer matches (stale cache -> slow/missing captures).
    private func window(withID windowID: CGWindowID, matching frame: CGRect) async throws -> SCWindow? {
        if let cached = shareableContent,
           let win = cached.windows.first(where: { $0.windowID == windowID }),
           frameMatches(win.frame, frame) {
            return win
        }
        let content = try await refreshContent()
        return content.windows.first { $0.windowID == windowID }
    }

    private func refreshContent() async throws -> SCShareableContent {
        let t1 = Date()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        shareableContent = content
        Log.info("SC refetch took \(Int(Date().timeIntervalSince(t1) * 1000))ms")
        return content
    }

    private func frameMatches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 10) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}
