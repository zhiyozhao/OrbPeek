import AppKit

// Shared by normal undock paths and crash recovery. Never leave a released
// window partially outside every screen's visible frame.
@MainActor
package func placeUndockedWindow(window: any WindowHandle, preferredFrame: CGRect?, fallbackFrame: CGRect? = nil,
                                 centered: Bool = false, geometry: WindowGeometry, canWrite: () -> Bool = { true }) {
    guard canWrite(), geometry.layout.isValid else { return }
    let candidate = preferredFrame ?? window.frame ?? fallbackFrame ?? .zero
    guard let screen = geometry.nearestScreen(to: candidate) else { return }
    var fitted = geometry.fitting(candidate, in: screen)
    if centered {
        let visible = geometry.quartzVisibleFrame(of: screen)
        fitted.origin = CGPoint(x: visible.midX - fitted.width / 2, y: visible.midY - fitted.height / 2)
    }
    let current = window.frame
    if current?.size != fitted.size, canWrite() { window.resize(to: fitted.size) }
    if preferredFrame != nil || centered || current?.origin != fitted.origin {
        if canWrite() { window.position = fitted.origin }
    }
}
