import Cocoa

let args = CommandLine.arguments
let x = args.count > 1 ? Double(args[1])! : 400
let y = args.count > 2 ? Double(args[2])! : 400

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let win = NSWindow(
    contentRect: NSRect(x: x, y: y, width: 400, height: 400),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered,
    defer: false
)
win.title = "OrbPeekTest"
win.orderFrontRegardless()
app.activate(ignoringOtherApps: true)
print("TESTWIN-FRAME \(win.frame)")
fflush(stdout)

// Keep ourselves frontmost for the first 6s so the dock hotkey always hits us,
// even if someone clicks around meanwhile.
var ticks = 0
Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
    ticks += 1
    if ticks > 15 { t.invalidate(); return }
    app.activate(ignoringOtherApps: true)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
app.run()
