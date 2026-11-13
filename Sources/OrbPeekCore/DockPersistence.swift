import AppKit
import Foundation

package struct PersistedRect: Codable, Equatable {
    package var x: Double
    package var y: Double
    package var width: Double
    package var height: Double

    package init(_ rect: CGRect) {
        x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
    }

    package var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

package struct DockedWindowRecord: Codable, Equatable {
    package var processID: pid_t
    package var bundleIdentifier: String?
    package var title: String?
    package var windowID: CGWindowID?
    package var restoreFrame: PersistedRect
    package var parkedFrame: PersistedRect
    package var dockScreenID: CGDirectDisplayID?
    package var edge: DockEdge

    package init(processID: pid_t, bundleIdentifier: String?, title: String?, windowID: CGWindowID?,
                 restoreFrame: CGRect, parkedFrame: CGRect, dockScreenID: CGDirectDisplayID?, edge: DockEdge) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.windowID = windowID
        self.restoreFrame = PersistedRect(restoreFrame)
        self.parkedFrame = PersistedRect(parkedFrame)
        self.dockScreenID = dockScreenID
        self.edge = edge
    }
}

// A small atomically-written journal. It is only a crash-recovery aid, not
// desired state to restore as docks: every successful launch recovery clears it.
package struct DockStateStore {
    package let fileURL: URL

    package init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrbPeek", isDirectory: true)
            .appendingPathComponent("docked-windows.json")
    }

    package func load() throws -> [DockedWindowRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([DockedWindowRecord].self, from: Data(contentsOf: fileURL))
    }

    package func save(_ records: [DockedWindowRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    package func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

@MainActor
package struct DockRecovery {
    package let store: DockStateStore

    package init(store: DockStateStore) { self.store = store }

    package func recover(geometry: WindowGeometry,
                         resolver: (DockedWindowRecord) -> (any WindowHandle)?) {
        guard let records = try? store.load() else {
            try? store.clear()
            return
        }
        defer { try? store.clear() }
        for record in records {
            guard let window = resolver(record), let frame = window.frame else { continue }
            let fullyVisible = geometry.layout.screens.contains {
                geometry.quartzVisibleFrame(of: $0).contains(frame)
            }
            if !fullyVisible {
                OrbPeekCore.placeUndockedWindow(window: window, preferredFrame: record.restoreFrame.rect,
                                                fallbackFrame: frame, geometry: geometry)
            }
        }
    }
}
