import CoreGraphics
import Foundation

// Borderless SnapshotStrip panels are omitted by Peekaboo's renderable-window
// inventory, so use the WindowServer inventory for their stable CGWindowID.
guard let pid = pid_t(CommandLine.arguments.dropFirst().first ?? "") else {
    print("usage: find-orbpeek-strip.swift <OrbPeek PID> [--count]")
    exit(2)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let strips = list.compactMap { item -> (id: CGWindowID, x: CGFloat, height: CGFloat)? in
    guard (item[kCGWindowOwnerPID as String] as? Int) == Int(pid),
          let bounds = item[kCGWindowBounds as String] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
          (frame.width <= 64 && frame.height >= 100) || (frame.height <= 64 && frame.width >= 100) else { return nil }
    return (CGWindowID(item[kCGWindowNumber as String] as? Int ?? 0), frame.minX, frame.height)
}
if CommandLine.arguments.contains("--count") {
    print(strips.count)
} else if let strip = strips.max(by: { $0.height < $1.height }) {
    print(strip.id)
} else {
    print("no preview strip found")
    exit(1)
}
