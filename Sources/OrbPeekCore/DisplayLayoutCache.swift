import AppKit

// One value snapshot per display-event generation. Invalidation happens even
// while suspended; only stable-layout reconciliation may change dock intent.
// Keep values, never NSScreen objects, and cache invalid layouts too so the
// write gate cannot fall back to an old valid desktop during reconfiguration.
@MainActor
package final class DisplayLayoutCache {
    private let load: () -> ScreenLayout
    private var snapshot: ScreenLayout?

    package init(load: @escaping () -> ScreenLayout = { ScreenLayout(screens: NSScreen.screens) }) {
        self.load = load
    }

    package var layout: ScreenLayout {
        if let snapshot { return snapshot }
        let current = load()
        snapshot = current
        return current
    }

    package var geometry: WindowGeometry { WindowGeometry(layoutProvider: { self.layout }) }

    package func invalidate() { snapshot = nil }
}
