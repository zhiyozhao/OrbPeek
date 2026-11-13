import CoreGraphics
import Foundation

// Deterministic mouse driver for testing: `--debug-mouse "t:x,y t:x,y ..."`
// overrides the cursor position seen by the poll (t = seconds since launch,
// positions in quartz/top-left coordinates, matching the log's frame values).
// When the flag is present the real cursor NEVER affects the app, so tests can
// run while the machine is in use.
enum DebugMouse {
    private static let script: [(t: TimeInterval, p: CGPoint)]? = {
        guard let i = CommandLine.arguments.firstIndex(of: "--debug-mouse"),
              CommandLine.arguments.indices.contains(i + 1) else { return nil }
        let parsed = CommandLine.arguments[i + 1].split(separator: " ").compactMap { item -> (t: TimeInterval, p: CGPoint)? in
            let kv = item.split(separator: ":")
            let xy = kv.last?.split(separator: ",") ?? []
            guard kv.count == 2, let t = Double(kv[0]), xy.count == 2,
                  let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
            return (t: t, p: CGPoint(x: x, y: y))
        }
        return parsed.isEmpty ? nil : parsed.sorted { $0.t < $1.t }
    }()

    static func location(sinceLaunch t: TimeInterval) -> CGPoint? {
        guard let script, let first = script.first else { return nil }
        return (script.last { $0.t <= t } ?? first).p
    }
}
