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
    package var cleanExit: Bool?
    package var exitedAt: Date?
    package var isCleanExit: Bool { cleanExit ?? false }

    package init(processID: pid_t, bundleIdentifier: String?, title: String?, windowID: CGWindowID?,
                 restoreFrame: CGRect, parkedFrame: CGRect, dockScreenID: CGDirectDisplayID?, edge: DockEdge,
                 cleanExit: Bool = false, exitedAt: Date? = nil) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.windowID = windowID
        self.restoreFrame = PersistedRect(restoreFrame)
        self.parkedFrame = PersistedRect(parkedFrame)
        self.dockScreenID = dockScreenID
        self.edge = edge
        self.cleanExit = cleanExit
        self.exitedAt = exitedAt
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
    package let redockAfterUpgrade: Bool
    package let now: () -> Date
    package var log: (String) -> Void

    package init(store: DockStateStore, redockAfterUpgrade: Bool = true,
                 now: @escaping () -> Date = Date.init, log: @escaping (String) -> Void = Log.info) {
        self.store = store
        self.redockAfterUpgrade = redockAfterUpgrade
        self.now = now
        self.log = log
    }

    package func recover(geometry: WindowGeometry,
                         resolver: (DockedWindowRecord) -> [any WindowHandle],
                         onRedock: ((DockedWindowRecord, any WindowHandle) -> Void)? = nil) {
        guard let records = try? store.load() else {
            log("launch recovery load failed; clear journal")
            try? store.clear()
            return
        }
        try? store.clear()
        log("launch recovery loaded records=\(records.count); journal cleared before actions")
        var recovered = Set<ObjectIdentifier>()
        for record in records {
            let candidates = resolver(record)
            log("recovery app=\(record.bundleIdentifier ?? "unknown") candidates=\(candidates.count) cleanExit=\(record.isCleanExit)")
            let titled = record.isCleanExit ? candidates : candidates.filter { record.title == nil || $0.title == record.title }
            let matched = titled.min { lhs, rhs in
                func score(_ window: any WindowHandle) -> CGFloat {
                    guard let frame = window.frame else { return .infinity }
                    let reference = record.isCleanExit ? record.restoreFrame.rect : record.parkedFrame.rect
                    return abs(frame.minX - reference.minX) + abs(frame.minY - reference.minY) +
                        abs(frame.width - reference.width) + abs(frame.height - reference.height)
                }
                return score(lhs) < score(rhs)
            }
            if record.isCleanExit {
                guard redockAfterUpgrade, let exitedAt = record.exitedAt else {
                    log("skip clean-exit record: policy or timestamp unavailable")
                    continue
                }
                let age = now().timeIntervalSince(exitedAt)
                guard age >= 0 && age <= 120 else {
                    log("skip expired clean-exit record age=\(Int(age))s")
                    continue
                }
                if let matched, let onRedock {
                    log("re-dock recovered window edge=\(record.edge) age=\(Int(age))s")
                    onRedock(record, matched)
                    recovered.insert(ObjectIdentifier(matched))
                } else {
                    log("clean-exit window not found; skip")
                }
                continue
            }
            if let matched, let frame = matched.frame {
                let fullyVisible = geometry.layout.screens.contains {
                    geometry.quartzVisibleFrame(of: $0).contains(frame)
                }
                if !fullyVisible {
                    log("crash recovery place matched window frame=\(frame)")
                    OrbPeekCore.placeUndockedWindow(window: matched, preferredFrame: record.restoreFrame.rect,
                                                    fallbackFrame: frame, geometry: geometry)
                    recovered.insert(ObjectIdentifier(matched))
                } else {
                    log("crash recovery matched window already visible; no-op")
                }
            } else {
                log("crash recovery matched window unavailable; skip")
            }

            // Titles are unstable in browsers/editors. Every window belonging
            // to a recorded app with <10% visible area is an OrbPeek leftover;
            // normal application windows do not park themselves off-screen.
            for window in candidates where !recovered.contains(ObjectIdentifier(window)) {
                guard let frame = window.frame, frame.width > 0, frame.height > 0 else { continue }
                let visibleArea = geometry.layout.screens.reduce(CGFloat.zero) { total, screen in
                    let intersection = geometry.quartzVisibleFrame(of: screen).intersection(frame)
                    return total + (intersection.isNull || intersection.isEmpty ? 0 : intersection.width * intersection.height)
                }
                guard visibleArea / (frame.width * frame.height) < 0.1 else { continue }
                log("crash recovery fallback visibleRatio=\(visibleArea / (frame.width * frame.height))")
                OrbPeekCore.placeUndockedWindow(window: window, preferredFrame: nil,
                                                fallbackFrame: frame, geometry: geometry)
                recovered.insert(ObjectIdentifier(window))
            }
        }
    }
}
