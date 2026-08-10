import ApplicationServices
import Cocoa

func runSelfTest() {
    let app = NSApplication.shared
    _ = app
    Log.info("=== self-test start ===")
    print("AX trusted:", AXWindow.isProcessTrusted)
    let front = NSWorkspace.shared.frontmostApplication
    print("frontmost app:", front?.localizedName ?? "nil", "pid:", front?.processIdentifier ?? -1)
    guard let pid = front?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier else {
        print("frontmost is self or nil; run from Terminal and keep Terminal frontmost")
        exit(1)
    }
    guard let window = AXWindow.focusedWindow(ofPID: pid) else {
        print("no focused window")
        exit(1)
    }
    guard let frame = window.frame else {
        print("cannot read frame — Accessibility permission missing")
        exit(1)
    }
    print("focused window frame:", frame)
    window.position = CGPoint(x: frame.origin.x + 30, y: frame.origin.y)
    usleep(300_000)
    if let f2 = window.frame {
        let ok = abs(f2.origin.x - (frame.origin.x + 30)) < 1
        print("after move:", f2.origin, ok ? "MOVE-OK" : "MOVE-FAILED-OR-REVERTED")
    } else {
        print("after move: cannot read frame")
    }
    window.position = frame.origin
    usleep(100_000)
    print("restored to", frame.origin)
    Log.info("=== self-test end ===")
    exit(0)
}
