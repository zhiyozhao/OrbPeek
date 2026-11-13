import AppKit

// Shared by normal undock paths and crash recovery. Never leave a released
// window partially outside every screen's visible frame.
@MainActor
package func placeUndockedWindow(window: any WindowHandle, preferredFrame: CGRect?, fallbackFrame: CGRect? = nil,
                                 geometry: WindowGeometry) {
    let candidate = preferredFrame ?? window.frame ?? fallbackFrame ?? .zero
    guard let screen = geometry.nearestScreen(to: candidate) else { return }
    let fitted = geometry.fitting(candidate, in: screen)
    let current = window.frame
    if current?.size != fitted.size { window.resize(to: fitted.size) }
    if preferredFrame != nil || current?.origin != fitted.origin {
        window.position = fitted.origin
    }
}
