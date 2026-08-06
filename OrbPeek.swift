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
    var orbSize: CGFloat = 32
    var orbOpacity: Double = 0.85
    var tuckKey: String = "t"
    var hideAllKey: String = "h"
    var peekAnimationMs: Double = 180
    var autoLaunch: Bool = false
    // Extra margin around the window treated as "inside" so edge/resize
    // interactions don't falsely hide the window.
    var edgeBuffer: CGFloat = 12

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
        if let v = json["tuckKey"] as? String { c.tuckKey = v }
        if let v = json["hideAllKey"] as? String { c.hideAllKey = v }
        if let v = json["autoLaunch"] as? Bool { c.autoLaunch = v }
        if let v = num("edgeBuffer") { c.edgeBuffer = CGFloat(v) }
        return c
    }

    static func saveDefault() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "orbSize": 32, "orbOpacity": 0.85,
            "tuckKey": "t", "hideAllKey": "h",
            "peekAnimationMs": 180,
            "autoLaunch": false, "edgeBuffer": 12,
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
    var icon: NSImage? {
        didSet {
            // Crop to the icon's actual non-transparent content so it fills the
            // orb regardless of the icon's own padding. Full-bleed icons (no
            // transparent margin) are cropped to ~nothing.
            icon = icon.flatMap { Self.cropped($0) }
            needsDisplay = true
        }
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
                      from: .zero, operation: .sourceOver, fraction: 1.0)
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
        if !dragged {
            // A click on the orb shows the window (drag = reposition only).
            owner?.setShown(true, animated: true)
        }
        dragStart = nil
    }
}

// MARK: - Managed window

final class ManagedWindow {
    let ax: AXUIElement
    // "Home" size/position of the window. Size is updated when the user resizes
    // the window while it is shown, so peek/hide anchors and release() all use
    // the live size. Position stays at the pre-manage spot (restore target).
    var homeFrame: CGRect
    let orb: OrbWindow
    weak var controller: OrbPeekController?

    // Core invariant: the window and the orb are NEVER visible at the same time.
    //   shown  — window visible at the orb-anchored position; orb is hidden.
    //   hidden — window tucked off-screen; orb visible (the only interaction point).
    private(set) var shown = false

    // User has the mouse button down on the window (native move/resize): the
    // window must stay shown until release, even if the pointer briefly leaves
    // its frame (stale AX frame during a live resize).
    var gesture = false

    // Consecutive ticks where the window frame could not be read; used to detect
    // a closed window (removed after ~1s) without flaking on transient failures.
    var nilCount = 0

    private var animTimer: Timer?
    private var valid = true

    var isAnimating: Bool { animTimer != nil }

    init(ax: AXUIElement, frame: CGRect, orb: OrbWindow, controller: OrbPeekController) {
        self.ax = ax
        self.homeFrame = frame
        self.orb = orb
        self.controller = controller
    }

    var appName: String {
        controller?.nameForWindow(ax) ?? "Window"
    }

    // Central transition — every show/hide decision routes through here.
    // `force` bypasses the state guard (used to tuck a freshly-managed window,
    // whose flag is already "hidden" but whose frame is still on screen).
    // Show animates in; hide is ALWAYS instant (teleports off-screen) so the
    // disappearing never feels in the way.
    func setShown(_ show: Bool, animated: Bool, force: Bool = false) {
        guard valid, force || shown != show else { return }
        shown = show
        if show {
            // Window replaces the orb: hide the orb, then show the window with
            // its top-right corner aligned to the orb's top-right corner.
            orb.orderOut(nil)
            let err = AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            if err != .success {
                Log.info("raise error \(err.rawValue)")
            }
            // The peek only renders above other apps if its app is frontmost.
            controller?.activateApp(self)
            let target = controller?.shownPos(for: self) ?? homeFrame.origin
            if animated {
                animate(to: target, duration: (controller?.config.peekAnimationMs ?? 180) / 1000)
            } else {
                axSetPosition(ax, target)
            }
        } else {
            // Window hands back to the orb: place the orb at the window's
            // current top-right corner, then teleport the window off-screen.
            if let f = axGetFrame(ax), let controller {
                controller.positionOrb(self, frame: f)
            }
            orb.orderFrontRegardless()
            let target = controller?.hiddenPos(for: self) ?? homeFrame.origin
            axSetPosition(ax, target)
        }
    }

    func collapseNow() {
        setShown(false, animated: false)
    }

    func tuck(animated: Bool) {
        setShown(false, animated: animated, force: true)
    }

    func release() {
        animTimer?.invalidate()
        animTimer = nil
        axSetPosition(ax, homeFrame.origin)
        axSetSize(ax, homeFrame.size)
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
    private func installMouseMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.handleGlobalMouseDown()
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.handleGlobalMouseUp()
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

    // While a window is shown the user may resize it natively. Track the new
    // size so the orb-anchored show position and the off-screen tuck both use
    // the live size (the orb itself only reappears when the window hides).
    private func trackResize(_ m: ManagedWindow, frame: CGRect) {
        guard m.shown else { return }
        let old = m.homeFrame.size
        if abs(frame.width - old.width) > 0.5 || abs(frame.height - old.height) > 0.5 {
            m.homeFrame.size = frame.size
        }
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
        let m = ManagedWindow(ax: axWin, frame: frame, orb: orb, controller: self)
        orb.owner = m
        managed.append(m)

        positionOrb(m, frame: frame)
        orb.orderFrontRegardless()
        // Snap the window off-screen immediately: no animation, so there is no
        // frame where the window and the orb are both visible.
        m.tuck(animated: false)
        rebuildMenu()
        Log.info("tucked window frame=\(frame), total managed=\(managed.count)")
    }

    @objc private func hideAll() {
        for m in managed {
            m.setShown(false, animated: true)
        }
        Log.info("hide all, count=\(managed.count)")
    }

    @objc private func toggleWindow(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? ManagedWindow else { return }
        m.setShown(!m.shown, animated: true)
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
            "autoLaunch": config.autoLaunch,
            "edgeBuffer": config.edgeBuffer,
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

    func shownPos(for m: ManagedWindow) -> CGPoint {
        // Corner alignment: the window's top-right corner sits exactly at the
        // orb's top-right corner (the orb rect extends into the window). This is
        // the exact inverse of positionOrb, so hide→show cycles never drift.
        // No clamping — the window may extend off-screen.
        let size = m.homeFrame.size
        let f = m.orb.frame
        let topRightX = f.minX - desktopFrame.minX + f.width
        let topRightY = desktopFrame.maxY - f.minY - f.height
        return CGPoint(x: topRightX - size.width, y: topRightY)
    }

    // macOS forces at least 1px of a window to stay on screen. Dock the window
    // off the NEARER outer edge of the whole desktop (never a display boundary),
    // so it genuinely disappears instead of sliding onto a neighboring screen.
    func hiddenPos(for m: ManagedWindow) -> CGPoint {
        let size = m.homeFrame.size
        let home = quartzVisibleFrame(of: screen(containingQuartz: m.homeFrame))
        let y = clamp(m.homeFrame.origin.y, home.minY, home.maxY - size.height)
        let orbCenter = m.orb.frame.center
        if orbCenter.x - desktopFrame.minX < desktopFrame.maxX - orbCenter.x {
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

    // Place the orb so its top-right corner sits exactly at the window's
    // top-right corner (the orb extends left/down into the window interior),
    // clamped to stay on-screen — on the DISPLAY of the window's frame (a
    // fullscreen window's corner can sit exactly on a seam; the frame's center
    // resolves the display unambiguously).
    func positionOrb(_ m: ManagedWindow, frame: CGRect) {
        let corner = CGPoint(x: frame.maxX, y: frame.minY)
        let size = config.orbSize
        let x = corner.x - size + desktopFrame.minX
        let y = desktopFrame.maxY - corner.y - size
        let scr = screen(containingQuartz: frame)
        let origin = clampOrbOrigin(NSPoint(x: x, y: y), screen: scr.visibleFrame)
        m.orb.setFrameOrigin(origin)
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

            // Let an in-flight animation settle before re-evaluating hover,
            // otherwise a window sliding under the cursor flips back and forth.
            if m.isAnimating { continue }
            // Repositioning the orb (visible only while the window is hidden)
            // should not peek the window.
            if m.orb.isDragging { continue }

            // A shown window may be resized natively; keep the anchor sizes in
            // sync so the next show/tuck uses the live dimensions.
            trackResize(m, frame: winFrame)

            // The user is mid-gesture (native move/resize of a shown window):
            // leave it alone — do not hide — until the button is released.
            if m.gesture { continue }

            let shouldShow = desiredState(m, hover: hover, inWin: inWin, front: front)
            if shouldShow != m.shown {
                m.setShown(shouldShow, animated: true)
            }
        }
        for m in toRemove { removeManaged(m) }
    }

    // Pure per-window decision function: whether the window should be shown next
    // tick. Showing is CLICK-triggered (on the orb, handled in OrbWindow.mouseUp),
    // so a hidden window stays hidden under the cursor. Leaving the window (or
    // switching apps) hides it — which brings the orb back at its current corner.
    private func desiredState(_ m: ManagedWindow, hover: Bool, inWin: Bool, front: Bool) -> Bool {
        guard m.shown else { return false }
        return front && inWin
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
