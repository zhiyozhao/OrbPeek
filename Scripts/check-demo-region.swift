import CoreGraphics
import Foundation

// Read-only privacy preflight. Never print app names, titles, or window content.
let parts = CommandLine.arguments.dropFirst().first?.split(separator: ",").compactMap { Double($0) } ?? []
guard parts.count == 4 else {
    print("region must be x,y,width,height")
    exit(2)
}
let region = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let occupied = list.contains { item in
    guard (item[kCGWindowLayer as String] as? Int ?? -1) == 0,
          let bounds = item[kCGWindowBounds as String] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
    return frame.intersects(region)
}
if occupied {
    print("DEMO_REGION is occupied by an existing window; choose an empty region first")
    exit(1)
}
print("DEMO_REGION is clear of existing layer-0 windows")
