import Cocoa
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Logging

enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/orbpeek.log"

    static func info(_ s: String) {
        let line = "[OrbPeek \(Date())] \(s)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard let fh = FileHandle(forWritingAtPath: path) else {
                try? line.write(toFile: path, atomically: false, encoding: .utf8)
                return
            }
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            try? fh.write(contentsOf: line.data(using: .utf8)!)
        }
    }
}

// MARK: - Config

struct Config {
    var orbSize: CGFloat = 38
    var orbOpacity: Double = 0.6
    var tuckKey: String = "t"
    var hideAllKey: String = "h"
    var autoLaunch: Bool = false
    // Extra margin around the window treated as "inside" so edge/resize
    // interactions don't falsely hide the window.
    var edgeBuffer: CGFloat = 12
    // Distance (px) from a screen edge at which a dragged orb snaps to it.
    // Only right/top edges are offered — the window's top-right corner is
    // anchored to the orb, so a left/bottom-snapped orb would hide the window.
    // Thickness (into the screen) and length (along the edge) of the parked
    // edge-strip the orb collapses into.
    var stripThickness: CGFloat = 6
    var stripLength: CGFloat = 48
    // Pressing ESC while a window is shown hides it (keyboard-first dismissal).
    var escToHide: Bool = true

    static let dir = NSHomeDirectory() + "/.config/orbpeek"
    static let path = dir + "/config.json"

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            saveDefault()
            return c
        }
        func num(_ k: String) -> Double? { (json[k] as? NSNumber)?.doubleValue }
        if let v = num("orbSize") { c.orbSize = CGFloat(v) }
        if let v = num("orbOpacity") { c.orbOpacity = v }
        if let v = json["tuckKey"] as? String { c.tuckKey = v }
        if let v = json["hideAllKey"] as? String { c.hideAllKey = v }
        if let v = json["autoLaunch"] as? Bool { c.autoLaunch = v }
        if let v = json["escToHide"] as? Bool { c.escToHide = v }
        if let v = num("edgeBuffer") { c.edgeBuffer = CGFloat(v) }
        if let v = num("stripThickness") { c.stripThickness = CGFloat(v) }
        if let v = num("stripLength") { c.stripLength = CGFloat(v) }
        return c
    }

    static func saveDefault() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "orbSize": 38, "orbOpacity": 0.6,
            "tuckKey": "t", "hideAllKey": "h",
            "autoLaunch": false, "edgeBuffer": 12,
            "stripThickness": 6, "stripLength": 48, "escToHide": true,
        ]
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - AX helpers

private func axGetFrame(_ el: AXUIElement) -> CGRect? {
    var posV: CFTypeRef?
    var sizeV: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
          let pv = posV, let sv = sizeV else { return nil }
    var p = CGPoint.zero
    var s = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &p),
          AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
    return CGRect(origin: p, size: s)
}

private func axSetPosition(_ el: AXUIElement, _ point: CGPoint) {
    var p = point
    guard let v = AXValueCreate(.cgPoint, &p) else { return }
    let err = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
    if err != .success {
        Log.info("axSetPosition error \(err.rawValue) to \(point)")
    }
}

private func axSetSize(_ el: AXUIElement, _ size: CGSize) {
    var s = size
    guard let v = AXValueCreate(.cgSize, &s) else { return }
    let err = AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
    if err != .success {
        Log.info("axSetSize error \(err.rawValue) to \(size)")
    }
}

// MARK: - Hotkey manager

private final class HotkeyManager {
    static let signature: OSType = 0x4F50454B // "OPEK"
    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var handlers: [UInt32: () -> Void] = [:]

    func register(id: UInt32, key: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        handlers[id] = handler
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(key, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        Log.info("hotkey id=\(id) key=\(key) mods=\(modifiers) register=\(err)")
        if let ref { refs.append(ref) }
    }

    func install() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let self_ = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                self_.handlers[hkID.id]?()
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    static func keyCode(for key: String) -> UInt32 {
        switch key.lowercased() {
        case "h": return UInt32(kVK_ANSI_H)
        case "p": return UInt32(kVK_ANSI_P)
        case "e": return UInt32(kVK_ANSI_E)
        case "y": return UInt32(kVK_ANSI_Y)
        case "x": return UInt32(kVK_ANSI_X)
        default: return UInt32(kVK_ANSI_T)
        }
    }
}

// MARK: - Orb view & window

// Screen edge the orb parks on while its window is hidden.
enum OrbEdge { case left, right, top, bottom }

final class OrbView: NSView {
    var highlighted = false {
        didSet { needsDisplay = true }
    }
    var opacity: Double = 0.85
    var icon: NSImage? {
        didSet {
            // Crop to the icon's actual non-transparent content so it fills the
            // orb regardless of the icon's own padding. Full-bleed icons (no
            // transparent margin) are cropped to ~nothing.
            icon = icon.flatMap { Self.cropped($0) }
            needsDisplay = true
        }
    }
    // When true the orb renders as a thin colored strip (parked on an edge);
    // otherwise as a square tile with the app icon (revealed on hover).
    var stripMode = false {
        didSet { needsDisplay = true }
    }
    var stripColor: NSColor = .gray {
        didSet { needsDisplay = true }
    }

    // The strip's fill color: the app icon's average color (weighted by alpha),
    // lifted off pure black so it stays visible on any desktop.
    static func averageColor(of image: NSImage) -> NSColor {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .gray }
        let sw = 16, sh = 16
        var pixels = [UInt8](repeating: 0, count: sw * sh * 4)
        guard let ctx = CGContext(data: &pixels, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .gray }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        var i = 0
        for _ in 0..<(sw * sh) {
            let a = Double(pixels[i + 3]) / 255.0
            if a > 0.2 {
                r += Double(pixels[i]) * a
                g += Double(pixels[i + 1]) * a
                b += Double(pixels[i + 2]) * a
                weight += a
            }
            i += 4
        }
        if weight == 0 { return .gray }
        return NSColor(
            calibratedRed: max(r / weight / 255.0, 0.35),
            green: max(g / weight / 255.0, 0.35),
            blue: max(b / weight / 255.0, 0.35),
            alpha: 1
        )
    }

    // Crop an app icon to its visible (non-transparent) bounding box.
    private static func cropped(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return image }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        var i = 0
        for y in 0..<h {
            for x in 0..<w {
                if pixels[i + 3] > 16 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                i += 4
            }
        }
        guard maxX >= 0 else { return image }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        if stripMode {
            // A thin rounded bar in the icon's color, sitting on the screen edge.
            let r = min(bounds.width, bounds.height) / 2
            let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: r, yRadius: r)
            stripColor.withAlphaComponent(opacity).setFill()
            body.fill()
            if highlighted {
                NSColor.systemBlue.setStroke()
                let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: r, yRadius: r)
                ring.lineWidth = 2
                ring.stroke()
            }
            return
        }

        let body = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)

        if let icon {
            NSGraphicsContext.current?.saveGraphicsState()
            body.addClip()
            // Aspect-fill the (already cropped) icon over the orb, centered.
            let target = bounds.insetBy(dx: 2, dy: 2)
            let s = icon.size
            let scale = max(target.width / max(s.width, 1), target.height / max(s.height, 1))
            let dw = s.width * scale
            let dh = s.height * scale
            icon.draw(in: CGRect(x: target.midX - dw / 2, y: target.midY - dh / 2, width: dw, height: dh),
                      from: .zero, operation: .sourceOver, fraction: opacity)
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            NSColor.darkGray.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }

        if highlighted {
            NSColor.systemBlue.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
            ring.lineWidth = 2.5
            ring.stroke()
        }
    }
}

final class OrbWindow: NSPanel {
    weak var owner: ManagedWindow?
    private var dragStart: NSPoint?
    private var dragged = false
    let orbView = OrbView()

    init(size: CGFloat, opacity: Double, icon: NSImage?) {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        orbView.opacity = opacity
        orbView.icon = icon
        contentView = orbView
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private(set) var isDragging = false

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragged = false
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let cur = event.locationInWindow
        let dx = cur.x - start.x
        let dy = cur.y - start.y
        if abs(dx) + abs(dy) > 3 { dragged = true; isDragging = true }
        var origin = frame.origin
        origin.x += dx
        origin.y += dy
        setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if dragged {
            // Repositioning the strip: re-dock it to the nearest screen edge.
            if let owner {
                owner.controller?.reParkOrb(owner)
            }
        } else {
            // A click on the strip/tile shows the window (drag = reposition).
            owner?.setShown(true)
        }
        dragStart = nil
    }
}

// MARK: - Managed window

final class ManagedWindow {
    let ax: AXUIElement
    // "Home" frame of the window: captured at manage time, used only to restore
    // the window when it is released (un-managed). Never mutated.
    let homeFrame: CGRect
    // The window's last position/size while visible — where it reappears on
    // show. Updated on hide so show/hide cycles are decoupled from the orb.
    var lastFrame: CGRect
    let orb: OrbWindow
    weak var controller: OrbPeekController?

    // Positions of the window and the orb are DECOUPLED:
    //   shown  — window visible at lastFrame; orb hidden (stays where it was).
    //   hidden — window tucked off-screen; orb reappears exactly where it was.
    private(set) var shown = false

    // Summoned windows are sticky: a window shown by clicking the orb stays even
    // with the mouse elsewhere. Once the mouse has dwelled inside it, leaving
    // hides it ("used it, left"). ESC / Cmd+Tab / hide-all dismiss it regardless.
    var touched = false
    private var inWinSince: Date?

    // When the window was summoned; the app is activated asynchronously, so for
    // a short grace the window must not be hidden by the "not frontmost" check.
    var shownSince: Date?

    // Where the orb's edge-strip parks while the window is hidden. STABLE state:
    // set at manage time and when the user drags the strip to a new edge — never
    // re-derived from the live position (an edge strip straddles a display seam,
    // so deriving the screen each tick makes it ping-pong between displays).
    var parkEdge: OrbEdge = .right
    var parkOffset: CGFloat = 0
    var parkScreen: NSScreen = NSScreen.main!
    var stripRevealed = false

    // User has the mouse button down on the window (native move/resize): the
    // window must stay shown until release, even if the pointer briefly leaves
    // its frame (stale AX frame during a live resize).
    var gesture = false

    // Consecutive ticks where the window frame could not be read; used to detect
    // a closed window (removed after ~1s) without flaking on transient failures.
    var nilCount = 0

    private var valid = true

    init(ax: AXUIElement, frame: CGRect, orb: OrbWindow, controller: OrbPeekController) {
        self.ax = ax
        self.homeFrame = frame
        self.lastFrame = frame
        self.orb = orb
        self.controller = controller
    }

    var appName: String {
        controller?.nameForWindow(ax) ?? "Window"
    }

    // Track "used it, left": the mouse must dwell inside the window for a beat
    // before counting as "used", so brushing past doesn't arm the dismiss.
    func noteHover(_ inWin: Bool) {
        if inWin {
            if inWinSince == nil { inWinSince = Date() }
            else if !touched, Date().timeIntervalSince(inWinSince!) >= 0.3 {
                touched = true
            }
        } else {
            inWinSince = nil
        }
    }

    // Central transition — every show/hide decision routes through here.
    // `force` bypasses the state guard (used to tuck a freshly-managed window,
    // whose flag is already "hidden" but whose frame is still on screen).
    // Both directions are INSTANT (teleport) — no slide animations.
    func setShown(_ show: Bool, force: Bool = false) {
        guard valid, force || shown != show else { return }
        shown = show
        if show {
            // Window replaces the strip: hide the strip, then restore the window
            // to its last position (positions are decoupled).
            shownSince = Date()
            orb.orderOut(nil)
            let err = AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            if err != .success {
                Log.info("raise error \(err.rawValue)")
            }
            // The peek only renders above other apps if its app is frontmost.
            controller?.activateApp(self)
            let target = controller?.restorePos(for: self) ?? lastFrame.origin
            axSetPosition(ax, target)
        } else {
            // Record where the window is now, then teleport it off-screen. The
            // orb (hidden while the window was shown) returns as the parked edge
            // strip at its stored parking spot.
            if let f = axGetFrame(ax) {
                lastFrame = f
            }
            touched = false
            inWinSince = nil
            shownSince = nil
            controller?.parkOrb(self)
            orb.orderFrontRegardless()
            let target = controller?.hiddenPos(for: self) ?? lastFrame.origin
            axSetPosition(ax, target)
        }
    }

    func collapseNow() {
        setShown(false)
    }

    func tuck() {
        setShown(false, force: true)
    }

    func release() {
        axSetPosition(ax, homeFrame.origin)
        axSetSize(ax, homeFrame.size)
        valid = false
        orb.orderOut(nil)
    }
}

// MARK: - Controller

final class OrbPeekController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var config: Config
    private let statusItem: NSStatusItem
    private let hotkeys = HotkeyManager()
    private var managed: [ManagedWindow] = []
    private var pollTimer: Timer?

    override init() {
        config = Config.load()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.title = "◉"
            button.font = NSFont.systemFont(ofSize: 12)
            button.toolTip = "OrbPeek — ⌃⌥T 接管/释放窗口,点击圆球显示"
        }
        rebuildMenu()
        statusItem.menu?.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched, pid=\(ProcessInfo.processInfo.processIdentifier), AX trusted=\(AXIsProcessTrusted())")

        hotkeys.install()
        let mods: UInt32 = UInt32(controlKey | optionKey)
        hotkeys.register(id: 1, key: HotkeyManager.keyCode(for: config.tuckKey), modifiers: mods) { [weak self] in
            self?.tuckFrontmost()
        }
        hotkeys.register(id: 2, key: HotkeyManager.keyCode(for: config.hideAllKey), modifiers: mods) { [weak self] in
            self?.hideAll()
        }

        installSignalHandlers()
        installMouseMonitors()

        if !AXIsProcessTrusted() {
            promptAccessibility()
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func installSignalHandlers() {
        let restore: @convention(c) (Int32) -> Void = { _ in
            DispatchQueue.main.async {
                (NSApplication.shared.delegate as? OrbPeekController)?.restoreAll()
                exit(0)
            }
        }
        signal(SIGTERM, restore)
        signal(SIGINT, restore)
    }

    // Track when the user holds the mouse button down on a shown window: that's
    // a native move/resize gesture, during which we must not hide the window.
    // (The orb is hidden while the window is shown, so there's nothing to exclude.)
    // Also listens for ESC to dismiss a shown window without touching the mouse.
    private func installMouseMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.handleGlobalMouseDown()
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.handleGlobalMouseUp()
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKey(event)
        }
    }

    private func handleGlobalKey(_ event: NSEvent) {
        // ESC hides any shown window (its app is frontmost). No-op when hidden.
        guard config.escToHide, event.keyCode == UInt16(kVK_Escape) else { return }
        for m in managed where m.shown {
            m.setShown(false)
        }
    }

    private func handleGlobalMouseDown() {
        let q = appKitToQuartz(NSEvent.mouseLocation)
        for m in managed where m.shown {
            guard let f = axGetFrame(m.ax) else { continue }
            let expanded = f.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer)
            if expanded.contains(q) {
                m.gesture = true
            }
        }
    }

    private func handleGlobalMouseUp() {
        for m in managed { m.gesture = false }
    }

    func restoreAll() {
        for m in managed { m.release() }
        managed.removeAll()
        rebuildMenu()
        Log.info("restored all windows on signal")
    }

    func applicationWillTerminate(_ notification: Notification) {
        for m in managed { m.release() }
        Log.info("terminated")
    }

    private func promptAccessibility() {
        let alert = NSAlert()
        alert.messageText = "OrbPeek 需要「辅助功能」权限"
        alert.informativeText = "否则无法移动窗口。请在系统设置 → 隐私与安全性 → 辅助功能 中勾选 OrbPeek（若未列出,点 + 添加）。\n\n授权后重新运行: ~/Codes/OrbPeek/OrbPeek"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let trusted = AXIsProcessTrusted()
        let permItem = NSMenuItem(title: trusted ? "权限:辅助功能 ✓" : "权限:辅助功能 ✗ (未授权)", action: nil, keyEquivalent: "")
        permItem.isEnabled = false
        menu.addItem(permItem)
        menu.addItem(.separator())

        let tuck = NSMenuItem(title: "接管/释放当前前台窗口 ⌃⌥\(config.tuckKey.uppercased())", action: #selector(tuckFrontmost), keyEquivalent: "")
        tuck.target = self
        menu.addItem(tuck)

        let hideAll = NSMenuItem(title: "一键全部缩回 ⌃⌥\(config.hideAllKey.uppercased())", action: #selector(hideAll), keyEquivalent: "")
        hideAll.target = self
        menu.addItem(hideAll)

        menu.addItem(.separator())

        if managed.isEmpty {
            let item = NSMenuItem(title: "还没有管理的窗口(按 ⌃⌥T 接管)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for (i, m) in managed.enumerated() {
                let title = "\(i + 1). \(m.appName) — \(m.shown ? "已显示" : "已折叠")"
                let item = NSMenuItem(title: title, action: #selector(toggleWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m
                menu.addItem(item)

                let release = NSMenuItem(title: "  释放该窗口", action: #selector(releaseWindow(_:)), keyEquivalent: "")
                release.target = self
                release.representedObject = m
                menu.addItem(release)
            }
        }

        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunch(_:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = config.autoLaunch ? .on : .off
        menu.addItem(launchItem)

        let openCfg = NSMenuItem(title: "打开配置文件…", action: #selector(openConfig), keyEquivalent: "")
        openCfg.target = self
        menu.addItem(openCfg)

        let viewLog = NSMenuItem(title: "打开日志…", action: #selector(openLog), keyEquivalent: "")
        viewLog.target = self
        menu.addItem(viewLog)

        let quit = NSMenuItem(title: "退出 OrbPeek", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: Actions

    @objc private func tuckFrontmost() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else {
            Log.info("tuck: frontmost is self or nil, pid=\(pid.map(String.init) ?? "nil")")
            return
        }
        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused)
        guard err == .success, let window = focused else {
            Log.info("tuck: no focused window err=\(err.rawValue)")
            return
        }
        let axWin = window as! AXUIElement

        // Toggle: if the frontmost window is already managed, release it.
        if let existing = managed.first(where: { CFEqual($0.ax, axWin) }) {
            removeManaged(existing)
            Log.info("released managed window via toggle, total managed=\(managed.count)")
            return
        }

        guard let frame = axGetFrame(axWin) else {
            Log.info("tuck: cannot read frame (check Accessibility permission)")
            return
        }
        guard frame.size.width > 0, frame.size.height > 0 else { return }

        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        let orb = OrbWindow(size: config.orbSize, opacity: config.orbOpacity, icon: icon)
        orb.orbView.stripColor = icon.map { OrbView.averageColor(of: $0) } ?? .gray
        let m = ManagedWindow(ax: axWin, frame: frame, orb: orb, controller: self)
        orb.owner = m
        managed.append(m)

        // Initial park: right edge of the window's screen, vertically aligned
        // with the window. tuck() then parks the strip and hides the window.
        m.parkScreen = screen(containingQuartz: frame)
        m.parkEdge = .right
        m.parkOffset = (desktopFrame.maxY - frame.midY) - config.stripLength / 2
        orb.orderFrontRegardless()
        // Snap the window off-screen immediately: no animation, so there is no
        // frame where the window and the orb are both visible.
        m.tuck()
        rebuildMenu()
        Log.info("tucked window frame=\(frame), total managed=\(managed.count)")
    }

    @objc private func hideAll() {
        for m in managed {
            m.setShown(false)
        }
        Log.info("hide all, count=\(managed.count)")
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? ManagedWindow else { return }
        m.setShown(!m.shown)
    }

    @objc private func releaseWindow(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? ManagedWindow else { return }
        removeManaged(m)
    }

    @objc private func toggleLaunch(_ sender: NSMenuItem) {
        setLaunchAtLogin(!config.autoLaunch)
        config.autoLaunch = !config.autoLaunch
        saveConfig()
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.path) { Config.saveDefault() }
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.path))
    }

    @objc private func openLog() {
        Log.info("log opened")
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.path))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        let path = NSHomeDirectory() + "/Library/LaunchAgents/com.orbpeek.OrbPeek.plist"
        if enable {
            let exe = CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": "com.orbpeek.OrbPeek",
                "ProgramArguments": [exe],
                "RunAtLoad": true,
            ]
            (plist as NSDictionary).write(to: URL(fileURLWithPath: path), atomically: true)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func saveConfig() {
        let dict: [String: Any] = [
            "orbSize": config.orbSize,
            "orbOpacity": config.orbOpacity,
            "tuckKey": config.tuckKey,
            "hideAllKey": config.hideAllKey,
            "autoLaunch": config.autoLaunch,
            "edgeBuffer": config.edgeBuffer,
            "stripThickness": config.stripThickness,
            "stripLength": config.stripLength,
            "escToHide": config.escToHide,
        ]
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: URL(fileURLWithPath: Config.path))
    }

    // MARK: Geometry

    func nameForWindow(_ el: AXUIElement) -> String {
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title) == .success,
              let t = title as? String, !t.isEmpty else { return "窗口" }
        return t
    }

    // Screen owning a quartz rect, by its CENTER — robust at display seams,
    // where edge-touching rects would ambiguously "intersect" both screens.
    private func screen(containingQuartz rect: CGRect) -> NSScreen {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { quartzFrame(of: $0).contains(center) } ?? NSScreen.main!
    }

    // NSScreen.frame is AppKit (bottom-left); flip to top-left over the union.
    private func quartzFrame(of s: NSScreen) -> CGRect {
        let f = s.frame
        return CGRect(x: f.minX, y: desktopFrame.maxY - f.maxY, width: f.width, height: f.height)
    }

    private func quartzVisibleFrame(of s: NSScreen) -> CGRect {
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: desktopFrame.maxY - v.maxY, width: v.width, height: v.height)
    }

    private var desktopFrame: CGRect {
        var r = NSScreen.screens[0].frame
        for s in NSScreen.screens.dropFirst() { r = r.union(s.frame) }
        return r
    }

    // Where the window reappears on show: its last position, unchanged.
    // Positions are decoupled from the orb, so the window is never constrained.
    func restorePos(for m: ManagedWindow) -> CGPoint {
        m.lastFrame.origin
    }

    // macOS forces at least 1px of a window to stay on screen. Dock the window
    // off the NEARER outer edge of the whole desktop (never a display boundary),
    // so it genuinely disappears instead of sliding onto a neighboring screen.
    func hiddenPos(for m: ManagedWindow) -> CGPoint {
        let size = m.lastFrame.size
        let home = quartzVisibleFrame(of: screen(containingQuartz: m.lastFrame))
        let y = clamp(m.lastFrame.origin.y, home.minY, home.maxY - size.height)
        let cx = m.lastFrame.midX
        if cx - desktopFrame.minX < desktopFrame.maxX - cx {
            return CGPoint(x: desktopFrame.minX - size.width + 1, y: y)
        } else {
            return CGPoint(x: desktopFrame.maxX - 1, y: y)
        }
    }

    // Frame of the parked edge-strip (thin, colored) for a window.
    private func stripRect(_ m: ManagedWindow) -> NSRect {
        let v = m.parkScreen.visibleFrame
        let t = config.stripThickness
        let l = config.stripLength
        switch m.parkEdge {
        case .left:
            return NSRect(x: v.minX, y: clamp(m.parkOffset, v.minY, v.maxY - l), width: t, height: l)
        case .right:
            return NSRect(x: v.maxX - t, y: clamp(m.parkOffset, v.minY, v.maxY - l), width: t, height: l)
        case .top:
            return NSRect(x: clamp(m.parkOffset, v.minX, v.maxX - l), y: v.maxY - t, width: l, height: t)
        case .bottom:
            return NSRect(x: clamp(m.parkOffset, v.minX, v.maxX - l), y: v.minY, width: l, height: t)
        }
    }

    // Frame of the revealed tile (square, shows the icon) centered on the strip.
    private func revealRect(_ m: ManagedWindow) -> NSRect {
        let v = m.parkScreen.visibleFrame
        let t = config.orbSize
        let s = stripRect(m)
        switch m.parkEdge {
        case .left:
            return NSRect(x: v.minX, y: clamp(s.midY - t / 2, v.minY, v.maxY - t), width: t, height: t)
        case .right:
            return NSRect(x: v.maxX - t, y: clamp(s.midY - t / 2, v.minY, v.maxY - t), width: t, height: t)
        case .top:
            return NSRect(x: clamp(s.midX - t / 2, v.minX, v.maxX - t), y: v.maxY - t, width: t, height: t)
        case .bottom:
            return NSRect(x: clamp(s.midX - t / 2, v.minX, v.maxX - t), y: v.minY, width: t, height: t)
        }
    }

    // Resolve a parked offset so the strip doesn't overlap other parked strips.
    // Tries the desired offset first, then steps of (strip length + gap) above
    // and below until a free slot is found, so strips stack along the edge.
    private func resolvedParkOffset(_ m: ManagedWindow, edge: OrbEdge, screen: NSScreen, desired: CGFloat) -> CGFloat {
        let v = screen.visibleFrame
        let l = config.stripLength
        let t = config.stripThickness
        let lo: CGFloat
        let hi: CGFloat
        switch edge {
        case .left, .right: lo = v.minY; hi = v.maxY - l
        case .top, .bottom: lo = v.minX; hi = v.maxX - l
        }
        let gap: CGFloat = 8
        let step = l + gap
        var candidates: [CGFloat] = []
        for i in 0...40 {
            candidates.append(desired - CGFloat(i) * step)
            candidates.append(desired + CGFloat(i) * step)
        }
        for cand in candidates {
            let off = clamp(cand, lo, hi)
            var probe: NSRect
            switch edge {
            case .left: probe = NSRect(x: v.minX, y: off, width: t, height: l)
            case .right: probe = NSRect(x: v.maxX - t, y: off, width: t, height: l)
            case .top: probe = NSRect(x: off, y: v.maxY - t, width: l, height: t)
            case .bottom: probe = NSRect(x: off, y: v.minY, width: l, height: t)
            }
            if !managed.contains(where: { $0 !== m && $0.orb.frame.intersects(probe) }) {
                return off
            }
        }
        return clamp(desired, lo, hi)
    }

    // Collapse the orb back to its parked strip at the stored parking spot,
    // nudged so it never overlaps another parked strip.
    func parkOrb(_ m: ManagedWindow) {
        m.parkOffset = resolvedParkOffset(m, edge: m.parkEdge, screen: m.parkScreen, desired: m.parkOffset)
        m.orb.orbView.stripMode = true
        m.orb.setFrame(stripRect(m), display: true)
        m.stripRevealed = false
    }

    // Expand the parked strip into a square tile showing the icon (hover feedback).
    func revealOrb(_ m: ManagedWindow) {
        m.orb.orbView.stripMode = false
        m.orb.setFrame(revealRect(m), display: true)
        m.stripRevealed = true
    }

    // After dragging the strip: dock it flush to the nearest edge of the screen
    // it is currently on (by its center), and record that as its stable parking
    // spot. Only the strip's own screen's edges are considered — searching every
    // display lets a visible-frame offset on a neighbor make the strip hop to
    // the wrong display.
    func reParkOrb(_ m: ManagedWindow) {
        let c = CGPoint(x: m.orb.frame.midX, y: m.orb.frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(c) }
            ?? NSScreen.screens.min {
                let d1 = hypot($0.frame.midX - c.x, $0.frame.midY - c.y)
                let d2 = hypot($1.frame.midX - c.x, $1.frame.midY - c.y)
                return d1 < d2
            }
            ?? NSScreen.main!
        let v = screen.visibleFrame
        let candidates: [(OrbEdge, CGFloat)] = [
            (.left, abs(c.x - v.minX)),
            (.right, abs(v.maxX - c.x)),
            (.top, abs(v.maxY - c.y)),
            (.bottom, abs(c.y - v.minY)),
        ]
        guard let best = candidates.min(by: { $0.1 < $1.1 }) else { return }
        m.parkEdge = best.0
        m.parkScreen = screen
        let rect = m.orb.frame
        switch best.0 {
        case .left, .right: m.parkOffset = rect.minY
        case .top, .bottom: m.parkOffset = rect.minX
        }
        parkOrb(m)
    }

    // MARK: Poll

    // NSEvent.mouseLocation is bottom-left (AppKit); AX positions and CGWindow
    // bounds are top-left over the same desktop union.
    private func appKitToQuartz(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - desktopFrame.minX, y: desktopFrame.maxY - p.y)
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let p = NSEvent.mouseLocation
        let q = appKitToQuartz(p)
        var toRemove: [ManagedWindow] = []
        for m in managed {
            guard let winFrame = axGetFrame(m.ax) else {
                // Window unreadable: likely closed. Only drop it after ~1s of
                // consecutive failures so transient AX hiccups don't lose it.
                m.nilCount += 1
                if m.nilCount > 30 { toRemove.append(m) }
                continue
            }
            m.nilCount = 0

            let hover = m.orb.frame.insetBy(dx: -8, dy: -8).contains(p)
            m.orb.orbView.highlighted = hover
            let inWin = winFrame.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer).contains(q)
            let front = appIsFrontmost(m)

            // Track "used it, left" for the sticky-dismiss rule.
            m.noteHover(inWin)

            // Repositioning the strip (visible only while the window is hidden)
            // should not peek the window.
            if m.orb.isDragging { continue }

            // The user is mid-gesture (native move/resize of a shown window):
            // leave it alone — do not hide — until the button is released.
            if m.gesture { continue }

            // Strip presentation while parked: hovering expands it to the icon
            // tile (so you can see which window it summons); leaving collapses
            // it back to the thin strip.
            if !m.shown {
                if hover {
                    if !m.stripRevealed { revealOrb(m) }
                } else if m.stripRevealed {
                    parkOrb(m)
                }
            }

            let shouldShow = desiredState(m, hover: hover, inWin: inWin, front: front)
            if shouldShow != m.shown {
                m.setShown(shouldShow)
            }
        }
        for m in toRemove { removeManaged(m) }
    }

    // Pure per-window decision function: whether the window should be shown next
    // tick. Showing is CLICK-triggered (on the orb). A summoned window is STICKY:
    // it stays shown even with the mouse elsewhere, and hides only when its app
    // stops being frontmost (Cmd+Tab), or the mouse has been used inside it and
    // then left. ESC / hide-all dismiss it as well.
    private func desiredState(_ m: ManagedWindow, hover: Bool, inWin: Bool, front: Bool) -> Bool {
        guard m.shown else { return false }
        // Grace period right after summon: the app is being activated
        // asynchronously, so don't let the "not frontmost" check kill the
        // window before the activation lands.
        if let since = m.shownSince, Date().timeIntervalSince(since) < 0.6 {
            return true
        }
        if !front { return false }
        if m.touched && !inWin { return false }
        return true
    }

    private func appIsFrontmost(_ m: ManagedWindow) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(m.ax, &pid) == .success else { return false }
        return pid == (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
    }

    func activateApp(_ m: ManagedWindow) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(m.ax, &pid) == .success else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    private func removeManaged(_ m: ManagedWindow) {
        m.release()
        managed.removeAll { $0 === m }
        rebuildMenu()
        Log.info("removed window, total managed=\(managed.count)")
    }
}

private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
    min(max(v, lo), hi)
}

// MARK: - Self test

func runSelfTest() {
    let app = NSApplication.shared
    _ = app
    Log.info("=== self-test start ===")
    print("AX trusted:", AXIsProcessTrusted())
    let front = NSWorkspace.shared.frontmostApplication
    print("frontmost app:", front?.localizedName ?? "nil", "pid:", front?.processIdentifier ?? -1, "bundle:", front?.bundleIdentifier ?? "nil")
    guard let pid = front?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier else {
        print("frontmost is self or nil; run from Terminal and keep Terminal frontmost")
        exit(1)
    }
    let axApp = AXUIElementCreateApplication(pid)
    var fw: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &fw)
    print("get focused window err:", err.rawValue)
    guard err == .success, let win = fw else {
        print("no focused window (is the app window frontmost?)")
        exit(1)
    }
    let axWin = win as! AXUIElement
    guard let frame = axGetFrame(axWin) else {
        print("cannot read frame — Accessibility permission missing or app not trusted")
        exit(1)
    }
    print("focused window frame:", frame)
    axSetPosition(axWin, CGPoint(x: frame.origin.x + 30, y: frame.origin.y))
    usleep(300_000)
    if let f2 = axGetFrame(axWin) {
        let ok = abs(f2.origin.x - (frame.origin.x + 30)) < 1
        print("after move:", f2.origin, ok ? "MOVE-OK" : "MOVE-FAILED-OR-REVERTED")
    } else {
        print("after move: cannot read frame")
    }
    axSetPosition(axWin, frame.origin)
    usleep(100_000)
    print("restored to", frame.origin)
    Log.info("=== self-test end ===")
    exit(0)
}

// MARK: - App entry

let app = NSApplication.shared
if CommandLine.arguments.contains("--self-test") {
    runSelfTest()
}
let controller = OrbPeekController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
