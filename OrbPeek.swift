import Cocoa
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit

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
    // Thickness of the fake snapshot sliver used for up/down docks (macOS won't
    // let a titled window leave the top/bottom, so those edges use a captured
    // slice of the window as the handle).
    var fakeSliverPx: CGFloat = 10

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
        if let v = num("fakeSliverPx") { c.fakeSliverPx = CGFloat(v) }
        return c
    }

    static func saveDefault() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "autoLaunch": false, "edgeBuffer": 12,
            "sliverPx": 6, "peekDwell": 0.15, "touchDwell": 0.3, "dockCancelPx": 40, "fakeSliverPx": 10,
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

// Edge a window can be docked to. macOS keeps a titled window's title bar
// on-screen, so the top/bottom edges use a fake snapshot sliver as the handle
// (left/right use the window's own visible slice).
enum DockEdge {
    case left, right, up, down
    var isFake: Bool { self == .up || self == .down }
}

// A floating strip that displays a captured slice of a docked window's content.
final class SnapshotStrip: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Hover/peek is detected geometrically by the poll, so the strip must not
        // swallow clicks aimed at whatever is below it.
        ignoresMouseEvents = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 2
        imageView.layer?.masksToBounds = true
        contentView = imageView
    }

    func show(image: NSImage?, frame: NSRect) {
        if let image {
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            imageView.layer?.backgroundColor = nil
        } else {
            // Slice not ready yet (or capture unavailable): keep the strip a
            // visible, hoverable handle with a neutral backing.
            imageView.image = nil
            imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        }
        setFrame(frame, display: true)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}

final class ManagedWindow {
    // A managed window is either hidden (docked, handle visible) or shown
    // (peeked, flush against its edge). Transitions are the only places phase
    // changes, and each one resets the transient dwell state uniformly.
    enum Phase {
        case docked, peeked
        var isDocked: Bool { self == .docked }
        var isPeeked: Bool { self == .peeked }
    }

    let ax: AXUIElement
    weak var controller: OrbPeekController?
    // Stable ordering tiebreak for overlapping slivers (same-size windows).
    let id = UUID()

    // Which edge the window is docked to (left/right real sliver, up/down fake).
    var edge: DockEdge
    // Preserved coordinate along the perpendicular axis (y for left/right,
    // x for up/down) — never moved when docking.
    var perp: CGFloat = 0
    // The on-screen frame at dock time, used to restore on quit.
    var restoreFrame: CGRect = .zero
    // The fake snapshot strip handle, only for up/down docks.
    var fakeStrip: SnapshotStrip?
    // Last captured slice, so re-showing the fake strip is instant.
    var lastSlice: NSImage?

    private(set) var phase: Phase = .docked

    // Dwell state, reset on every transition.
    private(set) var touched = false
    private var inWinSince: Date?
    private var shownSince: Date?
    private var sliverSince: Date?

    // User is dragging the peeked window (native move/resize).
    var gesture = false
    // Consecutive ticks where the window frame could not be read (closed window).
    var nilCount = 0
    private var valid = true

    init(ax: AXUIElement, edge: DockEdge, controller: OrbPeekController) {
        self.ax = ax
        self.edge = edge
        self.controller = controller
    }

    var appName: String {
        controller?.nameForWindow(ax) ?? "窗口"
    }

    var isFake: Bool { edge.isFake }

    // MARK: Transitions

    private func resetDwell() {
        touched = false
        inWinSince = nil
        sliverSince = nil
        shownSince = nil
    }

    // External guard: a minimized window doesn't respond to AX position changes.
    private func ensureNotMinimized() {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &v) == .success,
           let b = v as? Bool, b {
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    private func moveTo(_ pos: CGPoint) {
        axSetPosition(ax, pos)
    }

    // Dock (hide off the edge). `newEdge` re-docks to a different edge.
    func dock(to newEdge: DockEdge? = nil) {
        guard valid, let frame = axGetFrame(ax), let controller else { return }
        if let newEdge { edge = newEdge }
        ensureNotMinimized()
        phase = .docked
        resetDwell()
        if edge.isFake {
            if fakeStrip == nil { fakeStrip = SnapshotStrip() }
            controller.updateFakeStrip(self, windowFrame: frame, edge: edge)
            moveTo(controller.hiddenSidePos(self, size: frame.size))
        } else {
            fakeStrip?.hide()
            fakeStrip = nil
            moveTo(controller.dockedPos(self, size: frame.size))
        }
    }

    // Show flush against the edge.
    func peek() {
        guard valid, let frame = axGetFrame(ax), let controller else { return }
        ensureNotMinimized()
        phase = .peeked
        resetDwell()
        shownSince = Date()
        fakeStrip?.hide()
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        controller.activateApp(self)
        moveTo(controller.peekPos(self, size: frame.size))
    }

    // Hide again (docked ← peeked).
    private func dockBack() {
        guard valid, let frame = axGetFrame(ax), let controller else { return }
        ensureNotMinimized()
        phase = .docked
        resetDwell()
        if edge.isFake {
            if fakeStrip == nil { fakeStrip = SnapshotStrip() }
            controller.updateFakeStrip(self, windowFrame: frame, edge: edge)
            moveTo(controller.hiddenSidePos(self, size: frame.size))
        } else {
            moveTo(controller.dockedPos(self, size: frame.size))
        }
    }

    func togglePeek() {
        phase == .peeked ? dockBack() : peek()
    }

    // Stop tracking. A still-docked window is brought back flush first so it is
    // never left invisible; a peeked window stays where it is.
    func cancel() {
        guard valid else { return }
        if phase == .docked, let frame = axGetFrame(ax), let controller {
            moveTo(controller.peekPos(self, size: frame.size))
        }
        fakeStrip?.hide()
        fakeStrip = nil
        valid = false
        controller?.removeManaged(self)
    }

    // Called on drag release: pulled off the edge → cancel; otherwise remember
    // the new parallel position.
    func checkDragOut() {
        guard phase == .peeked, let frame = axGetFrame(ax), let controller else { return }
        if controller.distanceFromDockEdge(frame, edge: edge) > controller.config.dockCancelPx {
            cancel()
        } else {
            perp = controller.dockPerp(for: edge, frame: frame)
        }
    }

    // Restore on quit.
    func restore() {
        guard valid else { return }
        fakeStrip?.hide()
        fakeStrip = nil
        axSetPosition(ax, restoreFrame.origin)
        valid = false
    }

    // MARK: Poll evaluation

    private func noteHover(_ inWin: Bool) {
        if inWin {
            if inWinSince == nil { inWinSince = Date() }
            else if !touched, Date().timeIntervalSince(inWinSince!) >= (controller?.config.touchDwell ?? 0.3) {
                touched = true
            }
        } else {
            inWinSince = nil
        }
    }

    // One poll tick for this window. Returns true when the window should be
    // dropped (its frame is no longer readable → closed).
    @discardableResult
    func evaluate(mouseQ: CGPoint, frontmost: Bool, blockedByPeeked: Bool, blockedBySmaller: Bool, now: Date) -> Bool {
        guard valid, let controller else { return false }
        guard let frame = axGetFrame(ax) else {
            nilCount += 1
            return nilCount > 30
        }
        nilCount = 0
        guard !gesture else { return false }

        switch phase {
        case .peeked:
            // Remember the live parallel position (the user may move it).
            perp = controller.dockPerp(for: edge, frame: frame)
            let inWin = frame.insetBy(dx: -controller.config.edgeBuffer, dy: -controller.config.edgeBuffer).contains(mouseQ)
            noteHover(inWin)
            let onSliver = controller.sliverRect(self, size: frame.size).insetBy(dx: -6, dy: -6).contains(mouseQ)
            let grace = shownSince.map { now.timeIntervalSince($0) < 0.6 } ?? false
            if !grace, !frontmost || (touched && !inWin) || (!touched && !inWin && !onSliver) {
                dockBack()
            }
        case .docked:
            // Snap back to the docked position if it was moved externally.
            let target = edge.isFake ? controller.hiddenSidePos(self, size: frame.size) : controller.dockedPos(self, size: frame.size)
            if abs(frame.origin.x - target.x) > 2 || abs(frame.origin.y - target.y) > 2 {
                moveTo(target)
            }
            // Hover the handle to slide in (smallest window wins on overlap).
            let sliver = controller.sliverRect(self, size: frame.size).insetBy(dx: -6, dy: -6)
            if sliver.contains(mouseQ), !blockedByPeeked, !blockedBySmaller {
                if sliverSince == nil { sliverSince = now }
                else if now.timeIntervalSince(sliverSince!) >= controller.config.peekDwell { peek() }
            } else {
                sliverSince = nil
            }
        }
        return false
    }
}

// MARK: - Controller

final class OrbPeekController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var config: Config
    private let statusItem: NSStatusItem
    private let hotkeys = HotkeyManager()
    private var managed: [ManagedWindow] = []
    private var pollTimer: Timer?
    // Cached SCShareableContent (window list rarely changes) — avoids re-enumerating
    // all windows on every fake-strip capture.
    private var shareableContent: SCShareableContent?

    override init() {
        config = Config.load()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.title = "◉"
            button.font = NSFont.systemFont(ofSize: 12)
            button.toolTip = "OrbPeek — Ctrl+←/→/↑/↓ 把窗口贴到屏幕外,悬停边缘滑出"
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
        hotkeys.register(id: 3, key: UInt32(kVK_UpArrow), modifiers: mods) { [weak self] in self?.dockFrontmost(.up) }
        hotkeys.register(id: 4, key: UInt32(kVK_DownArrow), modifiers: mods) { [weak self] in self?.dockFrontmost(.down) }

        installSignalHandlers()
        installMouseMonitors()
        prewarmCapture()

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

    // Warm the ScreenCaptureKit pipeline at launch so the first fake-strip
    // capture doesn't pay the one-time enumeration/setup cost.
    private func prewarmCapture() {
        Task {
            if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
                shareableContent = c
            }
        }
    }

    private func handleGlobalMouseDown() {
        let q = appKitToQuartz(NSEvent.mouseLocation)
        for m in managed where m.phase.isPeeked {
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
            let item = NSMenuItem(title: "没有贴边的窗口(Ctrl+←/→/↑/↓ 贴边)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for (i, m) in managed.enumerated() {
                let title = "\(i + 1). \(m.appName) — \(m.phase.isPeeked ? "已滑出" : "已贴边")"
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
        m.togglePeek()
    }

    @objc private func cancelWindow(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? ManagedWindow else { return }
        m.cancel()
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
            "fakeSliverPx": config.fakeSliverPx,
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
            existing.perp = dockPerp(for: edge, frame: frame)
            existing.dock(to: edge)
            rebuildMenu()
            return
        }

        let m = ManagedWindow(ax: axWin, edge: edge, controller: self)
        m.perp = dockPerp(for: edge, frame: frame)
        m.restoreFrame = frame
        managed.append(m)
        m.dock()
        rebuildMenu()
        Log.info("docked window frame=\(frame) edge=\(edge), total=\(managed.count)")
    }

    func removeManaged(_ m: ManagedWindow) {
        m.fakeStrip?.hide()
        m.fakeStrip = nil
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

    // Convert a quartz (top-left) rect to AppKit (bottom-left) — needed when
    // positioning our own floating panels, whose frames are AppKit.
    private func appKitRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: desktopFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    // The perpendicular coordinate to preserve for an edge (y for left/right,
    // x for up/down).
    func dockPerp(for edge: DockEdge, frame: CGRect) -> CGFloat {
        switch edge {
        case .left, .right: return frame.minY
        case .up, .down: return frame.minX
        }
    }

    // The screen at the desktop's outer edge in the dock direction. For up/down
    // the relevant screen is the one at the window's perpendicular (x) — its
    // visible frame carries the menu-bar/dock offsets.
    private func outerScreen(for edge: DockEdge, perp: CGFloat) -> NSScreen {
        switch edge {
        case .left: return NSScreen.screens.min { $0.frame.minX < $1.frame.minX } ?? NSScreen.main!
        case .right: return NSScreen.screens.max { $0.frame.maxX < $1.frame.maxX } ?? NSScreen.main!
        case .up, .down:
            return NSScreen.screens.first { $0.frame.contains(CGPoint(x: perp, y: $0.frame.midY)) } ?? NSScreen.main!
        }
    }

    // Off-screen docked position for LEFT/RIGHT: mostly past the outer edge,
    // leaving sliverPx of the window visible (the handle).
    func dockedPos(_ m: ManagedWindow, size: CGSize) -> CGPoint {
        let v = quartzVisibleFrame(of: outerScreen(for: m.edge, perp: m.perp))
        switch m.edge {
        case .left: return CGPoint(x: v.minX - size.width + config.sliverPx, y: m.perp)
        case .right: return CGPoint(x: v.maxX - config.sliverPx, y: m.perp)
        default: return .zero
        }
    }

    // Hiding spot for UP/DOWN: the real window tucks off the desktop's right
    // outer edge leaving a 1px sliver (macOS keeps ~40px visible if fully off,
    // but allows 1px). The fake strip at the top/bottom is the real handle. Its
    // y matches the peek position so the window only slides horizontally when
    // recalled.
    func hiddenSidePos(_ m: ManagedWindow, size: CGSize) -> CGPoint {
        let v = quartzVisibleFrame(of: outerScreen(for: m.edge, perp: m.perp))
        let y: CGFloat
        switch m.edge {
        case .up: y = v.minY
        case .down: y = v.maxY - size.height
        default: y = 0
        }
        return CGPoint(x: desktopFrame.maxX - 1, y: y)
    }

    // Flush position the window slides back to when peeked.
    func peekPos(_ m: ManagedWindow, size: CGSize) -> CGPoint {
        let v = quartzVisibleFrame(of: outerScreen(for: m.edge, perp: m.perp))
        switch m.edge {
        case .left: return CGPoint(x: v.minX, y: m.perp)
        case .right: return CGPoint(x: v.maxX - size.width, y: m.perp)
        case .up: return CGPoint(x: m.perp, y: v.minY)
        case .down: return CGPoint(x: m.perp, y: v.maxY - size.height)
        }
    }

    // The handle rect (what you hover to peek): the window's own slice for
    // left/right, or the fake snapshot strip's frame for up/down.
    func sliverRect(_ m: ManagedWindow, size: CGSize) -> CGRect {
        let v = quartzVisibleFrame(of: outerScreen(for: m.edge, perp: m.perp))
        switch m.edge {
        case .left: return CGRect(x: v.minX, y: m.perp, width: config.sliverPx, height: size.height)
        case .right: return CGRect(x: v.maxX - config.sliverPx, y: m.perp, width: config.sliverPx, height: size.height)
        case .up: return CGRect(x: m.perp, y: v.minY, width: size.width, height: config.fakeSliverPx)
        case .down: return CGRect(x: m.perp, y: v.maxY - config.fakeSliverPx, width: size.width, height: config.fakeSliverPx)
        }
    }

    // How far a window's docked-side edge sits off its docked edge (used to
    // decide whether the user dragged it out of the dock).
    func distanceFromDockEdge(_ frame: CGRect, edge: DockEdge) -> CGFloat {
        let v = quartzVisibleFrame(of: outerScreen(for: edge, perp: frame.minX))
        switch edge {
        case .left: return frame.minX - v.minX
        case .right: return v.maxX - frame.maxX
        case .up: return frame.minY - v.minY
        case .down: return v.maxY - frame.maxY
        }
    }

    // Capture the edge slice of a window and show it in the fake strip (async —
    // the strip shows a placeholder until the capture lands).
    func updateFakeStrip(_ m: ManagedWindow, windowFrame: CGRect, edge: DockEdge) {
        guard let strip = m.fakeStrip else { return }
        let frame = appKitRect(sliverRect(m, size: windowFrame.size))
        strip.show(image: m.lastSlice, frame: frame)
        var pid: pid_t = 0
        guard AXUIElementGetPid(m.ax, &pid) == .success,
              let wid = windowID(for: pid, frame: windowFrame) else { return }
        captureSlice(of: wid, windowFrame: windowFrame, for: edge) { [weak self, weak m] image in
            guard let self, let m, let image else { return }
            m.lastSlice = image
            m.fakeStrip?.show(image: image, frame: self.appKitRect(self.sliverRect(m, size: windowFrame.size)))
        }
    }

    private func windowID(for pid: pid_t, frame: CGRect) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int) == Int(pid) else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let bx = b["X"] as? Double, let by = b["Y"] as? Double,
                  let bw = b["Width"] as? Double, let bh = b["Height"] as? Double else { continue }
            if abs(bx - frame.minX) < 5 && abs(by - frame.minY) < 5
                && abs(bw - frame.width) < 5 && abs(bh - frame.height) < 5 {
                return CGWindowID(w[kCGWindowNumber as String] as? Int ?? 0)
            }
        }
        return nil
    }

    // ScreenCaptureKit-based capture of a window's edge slice (includes the
    // title bar, so a down-dock's handle can show it). Crops via the filter's
    // sourceRect so only the thin slice is captured (fast), and caches the
    // shareable content to avoid re-enumerating windows each time.
    private func captureSlice(of windowID: CGWindowID, windowFrame: CGRect, for edge: DockEdge,
                              completion: @escaping (NSImage?) -> Void) {
        guard windowID != 0, windowFrame.width > 0 else { completion(nil); return }
        let t0 = Date()
        Task {
            let slice: NSImage?
            do {
                let content: SCShareableContent
                if let cached = shareableContent,
                   let cachedWin = cached.windows.first(where: { $0.windowID == windowID }),
                   abs(cachedWin.frame.minX - windowFrame.minX) < 10,
                   abs(cachedWin.frame.minY - windowFrame.minY) < 10,
                   abs(cachedWin.frame.width - windowFrame.width) < 10,
                   abs(cachedWin.frame.height - windowFrame.height) < 10 {
                    content = cached
                } else {
                    let t1 = Date()
                    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    shareableContent = content
                    Log.info("SC refetch \(windowID) took \(Int(Date().timeIntervalSince(t1) * 1000))ms")
                }
                guard let win = content.windows.first(where: { $0.windowID == windowID }) else {
                    await MainActor.run { completion(nil) }
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let sliceRect: CGRect
                switch edge {
                case .up: sliceRect = CGRect(x: 0, y: windowFrame.height - config.fakeSliverPx, width: windowFrame.width, height: config.fakeSliverPx)
                case .down: sliceRect = CGRect(x: 0, y: 0, width: windowFrame.width, height: config.fakeSliverPx)
                default: await MainActor.run { completion(nil) }; return
                }
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = sliceRect
                cfg.width = Int(sliceRect.width * 2)
                cfg.height = Int(sliceRect.height * 2)
                cfg.showsCursor = false
                let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                Log.info("captureImage took \(Int(Date().timeIntervalSince(t0) * 1000))ms, got=\(img != nil)")
                guard let img else {
                    await MainActor.run { completion(nil) }
                    return
                }
                slice = NSImage(cgImage: img, size: NSSize(width: sliceRect.width, height: sliceRect.height))
            } catch {
                slice = nil
            }
            await MainActor.run {
                completion(slice)
            }
        }
    }


    // The window's size along the sliver (height for left/right, width for
    // up/down) — used to pick the smallest window when slivers overlap.
    private func sliverSize(_ m: ManagedWindow, size: CGSize) -> CGFloat {
        switch m.edge {
        case .left, .right: return size.height
        case .up, .down: return size.width
        }
    }

    // True if another docked window whose sliver also sits under the cursor is
    // smaller (or equally small but earlier in the managed order) — so the
    // smallest window owns the overlap and the rest stay hidden.
    private func smallestDockedUnder(_ q: CGPoint, excluding m: ManagedWindow) -> Bool {
        guard let f = axGetFrame(m.ax) else { return false }
        let thisSize = sliverSize(m, size: f.size)
        for other in managed where other !== m && other.phase.isDocked {
            guard let of = axGetFrame(other.ax) else { continue }
            guard sliverRect(other, size: of.size).insetBy(dx: -6, dy: -6).contains(q) else { continue }
            let otherSize = sliverSize(other, size: of.size)
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
        let now = Date()
        var toRemove: [ManagedWindow] = []
        for m in managed {
            let blockedByPeeked = managed.contains { $0 !== m && $0.phase.isPeeked }
            let blockedBySmaller = m.phase.isDocked && smallestDockedUnder(q, excluding: m)
            if m.evaluate(mouseQ: q, frontmost: appIsFrontmost(m),
                          blockedByPeeked: blockedByPeeked, blockedBySmaller: blockedBySmaller,
                          now: now) {
                toRemove.append(m)
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
