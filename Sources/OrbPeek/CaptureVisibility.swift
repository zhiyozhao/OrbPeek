import CoreGraphics
import Foundation

struct CaptureLayer {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let alpha: Double
}

enum CaptureVisibility {
    // CGWindowList is front-to-back, across app boundaries and window levels.
    // Conservatively require the whole cached image to be unobscured.
    static func allows(frame: CGRect, target: CGWindowID, excludingPID: pid_t, layers: [CaptureLayer]) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == target }),
              abs(layers[index].frame.minX - frame.minX) <= 2,
              abs(layers[index].frame.minY - frame.minY) <= 2,
              abs(layers[index].frame.width - frame.width) <= 2,
              abs(layers[index].frame.height - frame.height) <= 2 else { return false }
        return !layers[..<index].contains {
            $0.pid != excludingPID && $0.alpha > 0 &&
                !$0.frame.intersection(frame).isEmpty && !$0.frame.intersection(frame).isNull
        }
    }

    static func current(frame: CGRect, target: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] else { return false }
        let layers: [CaptureLayer] = list.compactMap {
            guard let id = $0[kCGWindowNumber as String] as? UInt32,
                  let pid = $0[kCGWindowOwnerPID as String] as? Int32,
                  let rect = $0[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: rect as CFDictionary) else { return nil }
            return CaptureLayer(id: id, pid: pid, frame: frame, alpha: $0[kCGWindowAlpha as String] as? Double ?? 1)
        }
        return allows(frame: frame, target: target, excludingPID: getpid(), layers: layers)
    }
}
