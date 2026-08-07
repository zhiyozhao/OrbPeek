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
    var autoLaunch: Bool = false
    // Margin around the window treated as "inside" so resize/edge interactions
    // don't falsely dismiss a peeked window.
    var edgeBuffer: CGFloat = 12
    // Visible slice of a docked window — the "handle" you hover to peek it.
    var sliverPx: CGFloat = 6
    // Hover dwell on the sliver before the window slides in (avoids accidental peeks).
    var peekDwell: Double = 0.15
    // Dwell inside the peeked window before leaving counts as "used it, left".
    var touchDwell: Double = 0.3
    // Dragging the peeked window this far off its docked edge cancels the dock.
    var dockCancelPx: CGFloat = 40

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
        if let v = json["autoLaunch"] as? Bool { c.autoLaunch = v }
        if let v = num("edgeBuffer") { c.edgeBuffer = CGFloat(v) }
        if let v = num("sliverPx") { c.sliverPx = CGFloat(v) }
        if let v = num("peekDwell") { c.peekDwell = v }
        if let v = num("touchDwell") { c.touchDwell = v }
        if let v = num("dockCancelPx") { c.dockCancelPx = CGFloat(v) }
        return c
    }

    static func saveDefault() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "autoLaunch": false, "edgeBuffer": 12,
            "sliverPx": 6, "peekDwell": 0.15, "touchDwell": 0.3, "dockCancelPx": 40,
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
}

// MARK: - Docked window

// Edge a window can be docked to. Only left/right — macOS keeps a titled
// window's title bar on-screen, so the top edge can't leave the screen and a
// bottom dock would leave the whole title bar visible as the handle.
enum DockEdge { case left, right }

final class ManagedWindow {
    let ax: AXUIElement
    weak var controller: OrbPeekController?
    // Stable ordering tiebreak for overlapping slivers (same-size windows).
    let id = UUID()

    // nil = a normal window; an edge = docked off that edge (sliver visible).
    var dockEdge: DockEdge? = nil
    // Preserved coordinate along the perpendicular axis (y for left/right,
    // x for top/bottom) — never moved when docking.
    var dockPerp: CGFloat = 0
    // The on-screen frame at dock time, used to restore on quit.
    var restoreFrame: CGRect = .zero

    private(set) var peeked = false

    // "Used it, left" tracking: the mouse must dwell inside the peeked window
    // before leaving counts as a dismiss (avoids brushing past).
    var touched = false
    private var inWinSince: Date?
    // Hover dwell on the sliver before peeking.
    var sliverSince: Date?
    // User is dragging the peeked window (native move/resize).
    var gesture = false
    // Consecutive ticks where the window frame could not be read (closed window).
    var nilCount = 0
    private var valid = true

    init(ax: AXUIElement, controller: OrbPeekController) {
        self.ax = ax
        self.controller = controller
    }

    var appName: String {
        controller?.nameForWindow(ax) ?? "窗口"
    }

    func dock() {
        guard valid, dockEdge != nil, let frame = axGetFrame(ax) else { return }
        peeked = false
        touched = false
        inWinSince = nil
        sliverSince = nil
        let pos = controller?.dockedPos(self, size: frame.size) ?? frame.origin
        axSetPosition(ax, pos)
    }

    // Slide the window back in, flush against its docked edge.
    func peek() {
        guard valid, dockEdge != nil, let frame = axGetFrame(ax) else { return }
        peeked = true
        touched = false
        inWinSince = nil
        sliverSince = nil
        let pos = controller?.peekPos(self, size: frame.size) ?? frame.origin
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        controller?.activateApp(self)
        axSetPosition(ax, pos)
    }

    // Slide back out to the docked (off-screen) position.
    func dockBack() {
        guard valid, dockEdge != nil, let frame = axGetFrame(ax) else { return }
        peeked = false
        touched = false
        inWinSince = nil
        sliverSince = nil
        let pos = controller?.dockedPos(self, size: frame.size) ?? frame.origin
        axSetPosition(ax, pos)
    }

    // Leave the window where it is and stop tracking it.
    func cancelDock() {
        guard valid else { return }
        dockEdge = nil
        peeked = false
        touched = false
        inWinSince = nil
        sliverSince = nil
        controller?.removeManaged(self)
    }

    // Called on drag release: pulled off the edge → cancel; otherwise remember
    // the new parallel position.
    func checkDragOut() {
        guard peeked, let edge = dockEdge, let frame = axGetFrame(ax) else { return }
        if let controller, controller.distanceFromDockEdge(frame, edge: edge) > controller.config.dockCancelPx {
            cancelDock()
        } else {
            dockPerp = controller?.perpendicular(frame, for: edge) ?? dockPerp
        }
    }

    func noteHover(_ inWin: Bool) {
        if inWin {
            if inWinSince == nil { inWinSince = Date() }
            else if !touched, Date().timeIntervalSince(inWinSince!) >= (controller?.config.touchDwell ?? 0.3) {
                touched = true
            }
        } else {
            inWinSince = nil
        }
    }

    func restore() {
        guard valid else { return }
        axSetPosition(ax, restoreFrame.origin)
        valid = false
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
            button.toolTip = "OrbPeek — Ctrl+←/→ 把窗口贴到屏幕外,悬停边缘滑出"
        }
        rebuildMenu()
        statusItem.menu?.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched, pid=\(ProcessInfo.processInfo.processIdentifier), AX trusted=\(AXIsProcessTrusted())")

        hotkeys.install()
        let mods = UInt32(controlKey)
        hotkeys.register(id: 1, key: UInt32(kVK_LeftArrow), modifiers: mods) { [weak self] in self?.dockFrontmost(.left) }
        hotkeys.register(id: 2, key: UInt32(kVK_RightArrow), modifiers: mods) { [weak self] in self?.dockFrontmost(.right) }

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

    // Track mouse-down on a peeked window (native move/resize gesture) so we
    // don't dismiss it mid-drag, and resolve "dragged out of the edge" on release.
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
        for m in managed where m.peeked {
            guard let f = axGetFrame(m.ax) else { continue }
            if f.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer).contains(q) {
                m.gesture = true
            }
        }
    }

    private func handleGlobalMouseUp() {
        for m in managed where m.gesture {
            m.gesture = false
            m.checkDragOut()
        }
    }

    func restoreAll() {
        for m in managed { m.restore() }
        managed.removeAll()
        rebuildMenu()
        Log.info("restored all docked windows on signal")
    }

    func applicationWillTerminate(_ notification: Notification) {
        for m in managed { m.restore() }
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

        if managed.isEmpty {
            let item = NSMenuItem(title: "没有贴边的窗口(Ctrl+方向贴边)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for (i, m) in managed.enumerated() {
                let title = "\(i + 1). \(m.appName) — \(m.peeked ? "已滑出" : "已贴边")"
                let item = NSMenuItem(title: title, action: #selector(togglePeek(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m
                menu.addItem(item)

                let cancel = NSMenuItem(title: "  取消贴边", action: #selector(cancelWindow(_:)), keyEquivalent: "")
                cancel.target = self
                cancel.representedObject = m
                menu.addItem(cancel)
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

    @objc private func togglePeek(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? ManagedWindow else { return }
        m.peeked ? m.dockBack() : m.peek()
    }

    @objc private func cancelWindow(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? ManagedWindow else { return }
        m.cancelDock()
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
            "autoLaunch": config.autoLaunch,
            "edgeBuffer": config.edgeBuffer,
            "sliverPx": config.sliverPx,
            "peekDwell": config.peekDwell,
            "touchDwell": config.touchDwell,
            "dockCancelPx": config.dockCancelPx,
        ]
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: URL(fileURLWithPath: Config.path))
    }

    // MARK: Docking

    // Dock the frontmost window off the given edge of the desktop.
    private func dockFrontmost(_ edge: DockEdge) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused else { return }
        let axWin = window as! AXUIElement
        guard let frame = axGetFrame(axWin), frame.size.width > 0, frame.size.height > 0 else { return }

        if let existing = managed.first(where: { CFEqual($0.ax, axWin) }) {
            // Re-dock to a new edge.
            existing.dockEdge = edge
            existing.dockPerp = perpendicular(frame, for: edge)
            existing.dock()
            rebuildMenu()
            return
        }

        let m = ManagedWindow(ax: axWin, controller: self)
        m.dockEdge = edge
        m.dockPerp = perpendicular(frame, for: edge)
        m.restoreFrame = frame
        managed.append(m)
        m.dock()
        rebuildMenu()
        Log.info("docked window frame=\(frame) edge=\(edge), total=\(managed.count)")
    }

    func removeManaged(_ m: ManagedWindow) {
        managed.removeAll { $0 === m }
        rebuildMenu()
    }

    func nameForWindow(_ el: AXUIElement) -> String {
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &title) == .success,
              let t = title as? String, !t.isEmpty else { return "窗口" }
        return t
    }

    func activateApp(_ m: ManagedWindow) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(m.ax, &pid) == .success else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    private func appIsFrontmost(_ m: ManagedWindow) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(m.ax, &pid) == .success else { return false }
        return pid == (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
    }

    // MARK: Geometry

    private var desktopFrame: CGRect {
        var r = NSScreen.screens[0].frame
        for s in NSScreen.screens.dropFirst() { r = r.union(s.frame) }
        return r
    }

    private func appKitToQuartz(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - desktopFrame.minX, y: desktopFrame.maxY - p.y)
    }

    private func quartzVisibleFrame(of s: NSScreen) -> CGRect {
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: desktopFrame.maxY - v.maxY, width: v.width, height: v.height)
    }

    // The screen at the desktop's outer edge in the dock direction (leftmost or
    // rightmost display) — the docked window parks off its outer edge.
    private func outerScreen(for edge: DockEdge) -> NSScreen {
        switch edge {
        case .left: return NSScreen.screens.min { $0.frame.minX < $1.frame.minX } ?? NSScreen.main!
        case .right: return NSScreen.screens.max { $0.frame.maxX < $1.frame.maxX } ?? NSScreen.main!
        }
    }

    func perpendicular(_ frame: CGRect, for edge: DockEdge) -> CGFloat {
        frame.minY
    }

    // Off-screen docked position: mostly past the outer edge, leaving sliverPx
    // of the window visible (the handle). The perpendicular coordinate is kept.
    func dockedPos(_ m: ManagedWindow, size: CGSize) -> CGPoint {
        let v = quartzVisibleFrame(of: outerScreen(for: m.dockEdge!))
        switch m.dockEdge! {
        case .left: return CGPoint(x: v.minX - size.width + config.sliverPx, y: m.dockPerp)
        case .right: return CGPoint(x: v.maxX - config.sliverPx, y: m.dockPerp)
        }
    }

    // Flush position the window slides back to when peeked.
    func peekPos(_ m: ManagedWindow, size: CGSize) -> CGPoint {
        let v = quartzVisibleFrame(of: outerScreen(for: m.dockEdge!))
        switch m.dockEdge! {
        case .left: return CGPoint(x: v.minX, y: m.dockPerp)
        case .right: return CGPoint(x: v.maxX - size.width, y: m.dockPerp)
        }
    }

    // The visible slice of the window when docked (the hover handle).
    func sliverRect(_ m: ManagedWindow, size: CGSize) -> CGRect {
        let v = quartzVisibleFrame(of: outerScreen(for: m.dockEdge!))
        switch m.dockEdge! {
        case .left: return CGRect(x: v.minX, y: m.dockPerp, width: config.sliverPx, height: size.height)
        case .right: return CGRect(x: v.maxX - config.sliverPx, y: m.dockPerp, width: config.sliverPx, height: size.height)
        }
    }

    // How far a window's docked-side edge sits off its docked edge (used to
    // decide whether the user dragged it out of the dock).
    func distanceFromDockEdge(_ frame: CGRect, edge: DockEdge) -> CGFloat {
        let v = quartzVisibleFrame(of: outerScreen(for: edge))
        switch edge {
        case .left: return frame.minX - v.minX
        case .right: return v.maxX - frame.maxX
        }
    }


    // True if another docked window whose sliver also sits under the cursor is
    // smaller (or equally small but earlier in the managed order) — so the
    // smallest window owns the overlap and the rest stay hidden.
    private func smallestDockedUnder(_ q: CGPoint, excluding m: ManagedWindow) -> Bool {
        guard let f = axGetFrame(m.ax) else { return false }
        let thisSize = f.size.height
        for other in managed where other !== m && !other.peeked {
            guard let of = axGetFrame(other.ax) else { continue }
            guard sliverRect(other, size: of.size).insetBy(dx: -6, dy: -6).contains(q) else { continue }
            let otherSize = of.size.height
            if otherSize < thisSize || (otherSize == thisSize && other.id < m.id) {
                return true
            }
        }
        return false
    }

    // MARK: Poll

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let p = NSEvent.mouseLocation
        let q = appKitToQuartz(p)
        var toRemove: [ManagedWindow] = []
        for m in managed {
            guard let frame = axGetFrame(m.ax) else {
                m.nilCount += 1
                if m.nilCount > 30 { toRemove.append(m) }
                continue
            }
            m.nilCount = 0
            guard m.dockEdge != nil else { continue }
            if m.gesture { continue }

            if m.peeked {
                // Track the live parallel position (the user may move it).
                m.dockPerp = perpendicular(frame, for: m.dockEdge!)
                let inWin = frame.insetBy(dx: -config.edgeBuffer, dy: -config.edgeBuffer).contains(q)
                m.noteHover(inWin)
                let onSliver = sliverRect(m, size: frame.size).insetBy(dx: -6, dy: -6).contains(q)
                if !appIsFrontmost(m) {
                    m.dockBack()
                } else if m.touched && !inWin {
                    m.dockBack()
                } else if !m.touched && !inWin && !onSliver {
                    m.dockBack()
                }
            } else {
                // Docked: hover the sliver to slide the window back in. Only the
                // smallest window under the cursor peeks, and only one window
                // peeks at a time — otherwise overlapping slivers flip-flop.
                let sliver = sliverRect(m, size: frame.size).insetBy(dx: -6, dy: -6)
                if sliver.contains(q),
                   !managed.contains(where: { $0 !== m && $0.peeked }),
                   !smallestDockedUnder(q, excluding: m) {
                    if m.sliverSince == nil { m.sliverSince = Date() }
                    else if Date().timeIntervalSince(m.sliverSince!) >= config.peekDwell { m.peek() }
                } else {
                    m.sliverSince = nil
                }
            }
        }
        for m in toRemove { removeManaged(m) }
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
    print("frontmost app:", front?.localizedName ?? "nil", "pid:", front?.processIdentifier ?? -1)
    guard let pid = front?.processIdentifier, pid != ProcessInfo.processInfo.processIdentifier else {
        print("frontmost is self or nil; run from Terminal and keep Terminal frontmost")
        exit(1)
    }
    let axApp = AXUIElementCreateApplication(pid)
    var fw: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &fw)
    print("get focused window err:", err.rawValue)
    guard err == .success, let win = fw else {
        print("no focused window")
        exit(1)
    }
    let axWin = win as! AXUIElement
    guard let frame = axGetFrame(axWin) else {
        print("cannot read frame — Accessibility permission missing")
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
