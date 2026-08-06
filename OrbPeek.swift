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
    var orbSize: CGFloat = 28
    var orbOpacity: Double = 0.85
    var tuckKey: String = "t"
    var hideAllKey: String = "h"
    var peekAnimationMs: Double = 180
    var collapseAnimationMs: Double = 160
    var hideOrbWhenShown: Bool = false
    var autoLaunch: Bool = false

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
        if let v = num("peekAnimationMs") { c.peekAnimationMs = v }
        if let v = num("collapseAnimationMs") { c.collapseAnimationMs = v }
        if let v = json["tuckKey"] as? String { c.tuckKey = v }
        if let v = json["hideAllKey"] as? String { c.hideAllKey = v }
        if let v = json["hideOrbWhenShown"] as? Bool { c.hideOrbWhenShown = v }
        if let v = json["autoLaunch"] as? Bool { c.autoLaunch = v }
        return c
    }

    static func saveDefault() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "orbSize": 28, "orbOpacity": 0.85,
            "tuckKey": "t", "hideAllKey": "h",
            "peekAnimationMs": 180, "collapseAnimationMs": 160,
            "hideOrbWhenShown": false, "autoLaunch": false,
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

final class OrbView: NSView {
    var highlighted = false {
        didSet { needsDisplay = true }
    }
    var opacity: Double = 0.85

    override func draw(_ dirtyRect: NSRect) {
        let fill = highlighted ? NSColor.systemBlue : NSColor.darkGray
        fill.withAlphaComponent(opacity).setFill()
        let inset: CGFloat = highlighted ? 2 : 3
        NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).fill()

        if !highlighted {
            NSColor.white.withAlphaComponent(0.25).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }
}

final class OrbWindow: NSPanel {
    weak var owner: ManagedWindow?
    private var dragStart: NSPoint?
    private var dragged = false
    let orbView = OrbView()

    init(size: CGFloat, opacity: Double) {
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
        if !dragged {
            owner?.toggle()
        }
        dragStart = nil
    }
}

// MARK: - Managed window

final class ManagedWindow {
    enum State { case collapsed, shown }

    let ax: AXUIElement
    let originalFrame: CGRect
    let orb: OrbWindow
    weak var controller: OrbPeekController?

    private(set) var state: State = .collapsed
    private var animTimer: Timer?
    private var valid = true

    var isAnimating: Bool { animTimer != nil }

    init(ax: AXUIElement, frame: CGRect, orb: OrbWindow, controller: OrbPeekController) {
        self.ax = ax
        self.originalFrame = frame
        self.orb = orb
        self.controller = controller
    }

    var appName: String {
        controller?.nameForWindow(ax) ?? "Window"
    }

    func toggle() {
        setShown(state == .collapsed, animated: true)
    }

    func setShown(_ show: Bool, animated: Bool) {
        guard valid, state != (show ? .shown : .collapsed) else { return }
        state = show ? .shown : .collapsed
        guard let target = show ? controller?.shownPos(for: self) : controller?.hiddenPos(for: self) else { return }
        if show {
            // Bring the window to the front of its z-order (without activating the
            // app / stealing focus) so a background app's peek is actually visible.
            let err = AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            if err != .success {
                Log.info("raise error \(err.rawValue)")
            }
        }
        if animated {
            animate(to: target, duration: show ? (controller?.config.peekAnimationMs ?? 180) / 1000 : (controller?.config.collapseAnimationMs ?? 160) / 1000)
        } else {
            axSetPosition(ax, target)
        }
        if let controller, controller.config.hideOrbWhenShown {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animated ? 0.15 : 0
                orb.animator().alphaValue = show ? 0.12 : controller.config.orbOpacity
            }
        }
    }

    func collapseNow() {
        setShown(false, animated: false)
    }

    func tuck(animated: Bool) {
        guard valid else { return }
        state = .collapsed
        guard let target = controller?.hiddenPos(for: self) else { return }
        if animated {
            animate(to: target, duration: (controller?.config.collapseAnimationMs ?? 160) / 1000)
        } else {
            axSetPosition(ax, target)
        }
    }

    func release() {
        animTimer?.invalidate()
        animTimer = nil
        axSetPosition(ax, originalFrame.origin)
        axSetSize(ax, originalFrame.size)
        valid = false
        orb.orderOut(nil)
    }

    private func animate(to target: CGPoint, duration: TimeInterval) {
        animTimer?.invalidate()
        guard let start = axGetFrame(ax)?.origin else {
            axSetPosition(ax, target)
            return
        }
        Log.info("animate from \(start) -> \(target) dur=\(duration)")
        let dx = target.x - start.x
        let dy = target.y - start.y
        let steps = max(1, Int(duration * 60))
        var step = 0
        let timer = Timer(timeInterval: duration / Double(steps), repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            step += 1
            let f = CGFloat(step) / CGFloat(steps)
            axSetPosition(self.ax, CGPoint(x: start.x + dx * f, y: start.y + dy * f))
            if step >= steps {
                t.invalidate()
                self.animTimer = nil
                axSetPosition(self.ax, target)
                Log.info("animate done at \(target)")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
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
            button.toolTip = "OrbPeek — ⌃⌥T 接管/释放窗口,悬停圆球查看"
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
                let title = "\(i + 1). \(m.appName) — \(m.state == .shown ? "已显示" : "已折叠")"
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

        let orb = OrbWindow(size: config.orbSize, opacity: config.orbOpacity)
        let m = ManagedWindow(ax: axWin, frame: frame, orb: orb, controller: self)
        orb.owner = m
        managed.append(m)

        let origin = freeOrbOrigin(for: frame)
        orb.setFrameOrigin(origin)
        orb.orderFrontRegardless()
        m.tuck(animated: true)
        rebuildMenu()
        Log.info("tucked window frame=\(frame), orb at \(origin), total managed=\(managed.count)")
    }

    @objc private func hideAll() {
        for m in managed { m.tuck(animated: true) }
        Log.info("hide all, count=\(managed.count)")
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        (sender.representedObject as? ManagedWindow)?.toggle()
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
            "peekAnimationMs": config.peekAnimationMs,
            "collapseAnimationMs": config.collapseAnimationMs,
            "hideOrbWhenShown": config.hideOrbWhenShown,
            "autoLaunch": config.autoLaunch,
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

    private func screen(containing rect: CGRect) -> NSScreen {
        NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main!
    }

    private var desktopFrame: CGRect {
        var r = NSScreen.screens[0].frame
        for s in NSScreen.screens.dropFirst() { r = r.union(s.frame) }
        return r
    }

    func shownPos(for m: ManagedWindow) -> CGPoint {
        // The orb IS the window's top-right corner handle: pin the window's
        // top-right corner to the orb center so the orb and window are always
        // adjacent (no gap for the cursor to fall through between them).
        let fr = screen(containing: m.orb.frame).visibleFrame
        let size = m.originalFrame.size
        let orbCenter = appKitToQuartz(m.orb.frame.center)
        let x = clamp(orbCenter.x - size.width, fr.minX, fr.maxX - size.width)
        let y = clamp(orbCenter.y, fr.minY, fr.maxY - size.height)
        return CGPoint(x: x, y: y)
    }

    // macOS forces at least 1px of a window to stay on screen. Dock the window
    // off the DESKTOP's outer edge (never an interior display boundary), leaving
    // a 1px sliver — effectively invisible, and correct on any multi-display layout.
    func hiddenPos(for m: ManagedWindow) -> CGPoint {
        let fr = screen(containing: m.originalFrame).visibleFrame
        let size = m.originalFrame.size
        let y = clamp(m.originalFrame.origin.y, fr.minY, fr.maxY - size.height)
        let orbCenter = m.orb.frame.center
        if orbCenter.x < desktopFrame.midX {
            return CGPoint(x: desktopFrame.minX - size.width + 1, y: y)
        } else {
            return CGPoint(x: desktopFrame.maxX - 1, y: y)
        }
    }

    private func clampOrbOrigin(_ o: NSPoint, screen fr: CGRect) -> NSPoint {
        NSPoint(
            x: clamp(o.x, fr.minX, fr.maxX - config.orbSize),
            y: clamp(o.y, fr.minY, fr.maxY - config.orbSize)
        )
    }

    // Orb starts centered on the window's top-right corner (quartz space, then
    // converted to AppKit); cascade left/up so multiple orbs never overlap.
    private func freeOrbOrigin(for frame: CGRect) -> NSPoint {
        let fr = screen(containing: frame).visibleFrame
        let size = config.orbSize
        let corner = CGPoint(x: frame.maxX, y: frame.minY)
        let qx = corner.x - size / 2
        let qy = corner.y - size / 2
        var origin = NSPoint(x: qx + desktopFrame.minX, y: desktopFrame.maxY - qy - size)
        origin = clampOrbOrigin(origin, screen: fr)
        var attempts = 0
        var probe = CGRect(origin: origin, size: CGSize(width: size, height: size))
        while attempts < 50, managed.contains(where: { $0.orb.frame.intersects(probe) }) {
            origin.x -= size + 8
            if origin.x < fr.minX {
                origin.x = fr.maxX - size - 8
                origin.y -= size + 8
            }
            probe.origin = origin
            attempts += 1
        }
        return clampOrbOrigin(origin, screen: fr)
    }

    // MARK: Poll

    // The frontmost normal (layer 0) window under a given AppKit point, if any.
    // CGWindowList is ordered front-to-back and uses a top-left origin (same
    // space as AX positions); only the mouse point needs flipping from AppKit.
    private func topmostWindowFrame(at p: CGPoint) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let q = appKitToQuartz(p)
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int ?? 0) == 0 else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let bx = b["X"] as? Double, let by = b["Y"] as? Double,
                  let bw = b["Width"] as? Double, let bh = b["Height"] as? Double else { continue }
            if q.x >= bx, q.x < bx + bw, q.y >= by, q.y < by + bh {
                return CGRect(x: bx, y: by, width: bw, height: bh)
            }
        }
        return nil
    }

    // NSEvent.mouseLocation is bottom-left (AppKit); AX positions and CGWindow
    // bounds are top-left over the same desktop union.
    private func appKitToQuartz(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - desktopFrame.minX, y: desktopFrame.maxY - p.y)
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let p = NSEvent.mouseLocation
        let q = appKitToQuartz(p)
        // Cache the frontmost window under the cursor once per tick. A shown
        // window must still be the frontmost window there to stay out — if another
        // window/app has come on top of it, tuck it back.
        var topFrame: CGRect?
        if managed.contains(where: { $0.state == .shown && !$0.isAnimating }) {
            topFrame = topmostWindowFrame(at: p)
        }
        var toRemove: [ManagedWindow] = []
        for m in managed {
            let orbFrame = m.orb.frame
            let inflated = orbFrame.insetBy(dx: -8, dy: -8)
            let inOrb = inflated.contains(p)
            let winFrame = axGetFrame(m.ax)
            let inWin = winFrame?.contains(q) ?? false

            var shouldShow = inOrb || inWin
            if shouldShow, inWin, !inOrb, let top = topFrame {
                shouldShow = abs(top.minX - winFrame!.minX) <= 3
                    && abs(top.minY - winFrame!.minY) <= 3
                    && abs(top.width - winFrame!.width) <= 3
                    && abs(top.height - winFrame!.height) <= 3
            }

            m.orb.orbView.highlighted = inOrb

            // Let an in-flight animation settle before re-evaluating hover,
            // otherwise a window sliding under the cursor flips back and forth.
            if m.isAnimating { continue }
            // Repositioning the orb (drag) should not peek/hide the window.
            if m.orb.isDragging { continue }

            if shouldShow != (m.state == .shown) {
                m.setShown(shouldShow, animated: true)
            }

            if winFrame == nil, m.state == .collapsed {
                toRemove.append(m)
            }
        }
        for m in toRemove { removeManaged(m) }
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

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
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
