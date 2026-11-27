import Foundation
import ScreenCaptureKit

// SCK may never complete even after its deadline. Bound outstanding system
// requests as well as caller latency; late results cannot mutate app state.
final class CaptureRequestBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int
    init(limit: Int = 8) { self.limit = limit }
    func acquire() throws {
        try lock.withLock {
            guard count < limit else { throw NSError(domain: "OrbPeek.CaptureBusy", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "outstanding ScreenCaptureKit request limit reached"]) }
            count += 1
        }
    }
    func release() { lock.withLock { count -= 1 } }
}

// Nonisolated async functions run on the generic executor, not MainActor.
enum ScreenCaptureService {
    private static let budget = CaptureRequestBudget()
    static func content() async throws -> CaptureContent? {
        try budget.acquire()
        defer { budget.release() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return CaptureContent(displays: content.displays.map { display in
            CaptureDisplay(id: display.displayID, frame: display.frame) { local in
                try await image(display: display, content: content, local: local)
            }
        }, containsOwnApplication: content.applications.contains { $0.processID == ownPID })
    }

    private static func image(display: SCDisplay, content: SCShareableContent, local: CGRect) async throws -> CGImage? {
        try budget.acquire()
        defer { budget.release() }
        guard let layers = CaptureVisibility.currentLayers() else {
            throw NSError(domain: "OrbPeek.CaptureWindowList", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "current window list unavailable"])
        }
        let frame = local.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        let plan = try CaptureFilterPlan.make(frame: frame, layers: layers, ownPID: getpid(),
            availableApplications: Set(content.applications.map(\.processID)),
            windows: content.windows.map { CaptureFilterWindow(id: $0.windowID, pid: $0.owningApplication?.processID ?? 0, layer: $0.windowLayer) })
        let excluded = content.applications.filter { plan.applications.contains($0.processID) }
        let exceptions = content.windows.filter { plan.exceptions.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: exceptions)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = local
        cfg.width = max(1, Int(local.width * CGFloat(filter.pointPixelScale)))
        cfg.height = max(1, Int(local.height * CGFloat(filter.pointPixelScale)))
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}
