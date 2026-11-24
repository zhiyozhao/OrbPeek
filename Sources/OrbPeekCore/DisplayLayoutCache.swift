import AppKit

// Events invalidate immediately; a two-second full-value fingerprint read also
// catches missed events (including visibleFrame-only changes). Only stable
// layout reconciliation may change dock intent.
// Keep values, never NSScreen objects, and cache invalid layouts too so the
// write gate cannot fall back to an old valid desktop during reconfiguration.
@MainActor
package final class DisplayLayoutCache {
    private let load: () -> ScreenLayout
    private let clock: () -> Date
    private var snapshot: ScreenLayout?
    private var checkedAt: Date?

    package init(load: @escaping () -> ScreenLayout = { ScreenLayout(screens: NSScreen.screens) },
                 clock: @escaping () -> Date = Date.init) {
        self.load = load
        self.clock = clock
    }

    package var layout: ScreenLayout {
        let now = clock()
        if let snapshot, let checkedAt,
           now >= checkedAt, now.timeIntervalSince(checkedAt) < 2 { return snapshot }
        // Compare all fields, including UUID and mirror relationships. Reuse
        // this read as the new snapshot when changed, without loading twice.
        let current = load()
        if snapshot != current { snapshot = current }
        checkedAt = now
        return snapshot ?? current
    }

    package var geometry: WindowGeometry { WindowGeometry(layoutProvider: { self.layout }) }

    package func invalidate() { snapshot = nil }
}
