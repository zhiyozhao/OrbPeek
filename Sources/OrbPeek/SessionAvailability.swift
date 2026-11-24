import CoreGraphics

// CGSession's exported key differs from the C symbol's spelling.
// Unknown session data must never authorize writes to another user's desktop.
struct SessionAvailability {
    let isActive: Bool
    let isLocked: Bool

    init(snapshot: [String: Any]?) {
        isActive = (snapshot?[kCGSessionOnConsoleKey as String] as? Bool) ?? false
        isLocked = snapshot == nil || ((snapshot?["CGSSessionScreenIsLocked"] as? Bool) ?? false)
    }
}
