import CoreGraphics
import Foundation
import AppKit

struct CaptureLayer {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let alpha: Double
    var layer: Int = 0
    var systemDecoration: Bool = false

    var isDecoration: Bool { layer != 0 || alpha <= 0 || systemDecoration }
    // Retain the desktop's backing surface for translucent window pixels.
    var isDesktopBacking: Bool { layer <= CGWindowLevelForKey(.desktopWindow) }
}

enum CaptureVisibility {
    // CGWindowList is front-to-back, across app boundaries and window levels.
    // Conservatively require the whole cached image to be unobscured.
    static func allows(frame: CGRect, target: CGWindowID, excludingPID: pid_t, layers: [CaptureLayer]) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == target }),
              !layers[index].isDecoration,
              abs(layers[index].frame.minX - frame.minX) <= 2,
              abs(layers[index].frame.minY - frame.minY) <= 2,
              abs(layers[index].frame.width - frame.width) <= 2,
              abs(layers[index].frame.height - frame.height) <= 2 else { return false }
        return !layers[..<index].contains {
            $0.pid != excludingPID && !$0.isDecoration &&
                !$0.frame.intersection(frame).isEmpty && !$0.frame.intersection(frame).isNull
        }
    }

    static func current(frame: CGRect, target: CGWindowID) -> Bool {
        guard let layers = currentLayers() else { return false }
        return allows(frame: frame, target: target, excludingPID: getpid(), layers: layers)
    }

    static func currentLayers() -> [CaptureLayer]? {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] else { return nil }
        var systems: [pid_t: Bool] = [:]
        let layers: [CaptureLayer] = list.compactMap {
            guard let id = $0[kCGWindowNumber as String] as? UInt32,
                  let pid = $0[kCGWindowOwnerPID as String] as? Int32,
                  let rect = $0[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return nil }
            if systems[pid] == nil {
                let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                systems[pid] = ["com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver"].contains(bundle)
            }
            return CaptureLayer(id: id, pid: pid, frame: frame, alpha: $0[kCGWindowAlpha as String] as? Double ?? 1,
                layer: $0[kCGWindowLayer as String] as? Int ?? 0, systemDecoration: systems[pid] ?? false)
        }
        return layers
    }
}

struct CaptureFilterWindow {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
}

// The application exclusion initializer's exceptions invert membership:
// excluded apps' normal windows are included; other apps' decorations excluded.
// This also handles sharingState=0 overlays absent from SCWindow enumeration
// when their application is present. SharingState is not an opacity signal.
struct CaptureFilterPlan {
    let applications: Set<pid_t>
    let exceptions: Set<CGWindowID>

    static func make(frame: CGRect, layers: [CaptureLayer], ownPID: pid_t,
                     availableApplications: Set<pid_t>, windows: [CaptureFilterWindow]) throws -> Self {
        let relevant = layers.filter { $0.frame.intersects(frame) }
        let decorations = relevant.filter { $0.isDecoration && !$0.isDesktopBacking }
        let wantedApps = Set(decorations.map(\.pid)).union([ownPID])
        let excludedApps = wantedApps.intersection(availableApplications)
        let knownIDs = Set(windows.map(\.id))
        let missingDecorations = decorations.filter { !excludedApps.contains($0.pid) && !knownIDs.contains($0.id) }
        let missingNormals = relevant.filter {
            $0.pid != ownPID && excludedApps.contains($0.pid) && !$0.isDecoration && !knownIDs.contains($0.id)
        }
        guard missingDecorations.isEmpty, missingNormals.isEmpty else {
            throw NSError(domain: "OrbPeek.StaleCaptureWindows", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "new overlay/normal windows need fresh content: \((missingDecorations + missingNormals).map(\.id))"])
        }
        let current = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let exceptions = windows.filter { window in
            guard window.pid != ownPID else { return !excludedApps.contains(ownPID) }
            let decoration = current[window.id].map { $0.isDecoration && !$0.isDesktopBacking }
                ?? (window.layer != 0 && window.layer > CGWindowLevelForKey(.desktopWindow))
            return excludedApps.contains(window.pid) ? !decoration : decoration
        }
        return Self(applications: excludedApps, exceptions: Set(exceptions.map(\.id)))
    }
}
