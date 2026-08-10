import Carbon.HIToolbox
import Cocoa

@MainActor
@main
final class OrbPeekController: NSObject, NSApplicationDelegate, NSMenuDelegate, WindowDockDelegate {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
        }
        let app = NSApplication.shared
        let controller = OrbPeekController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }

    var config: Config
    let geometry = WindowGeometry()
    let capturer = SliceCapturer()

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
            button.toolTip = "OrbPeek — Ctrl+←/→/↑/↓ 把窗口贴到屏幕外,悬停边缘滑出"
        }
        rebuildMenu()
        statusItem.menu?.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched, pid=\(ProcessInfo.processInfo.processIdentifier), AX trusted=\(AXWindow.isProcessTrusted)")

        hotkeys.install()
        let mods = UInt32(controlKey)
        hotkeys.register(id: 1, key: UInt32(kVK_LeftArrow), modifiers: mods) { [weak self] in
            Task { @MainActor in self?.dockFrontmost(.left) }
        }
        hotkeys.register(id: 2, key: UInt32(kVK_RightArrow), modifiers: mods) { [weak self] in
            Task { @MainActor in self?.dockFrontmost(.right) }
        }
        hotkeys.register(id: 3, key: UInt32(kVK_UpArrow), modifiers: mods) { [weak self] in
            Task { @MainActor in self?.dockFrontmost(.up) }
        }
        hotkeys.register(id: 4, key: UInt32(kVK_DownArrow), modifiers: mods) { [weak self] in
            Task { @MainActor in self?.dockFrontmost(.down) }
        }

        installSignalHandlers()
        installMouseMonitors()
        capturer.prewarm()

        if !AXWindow.isProcessTrusted {
            promptAccessibility()
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func installSignalHandlers() {
        let restore: @convention(c) (Int32) -> Void = { _ in
            Task { @MainActor in
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
            Task { @MainActor in self?.handleGlobalMouseDown() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in self?.handleGlobalMouseUp() }
        }
    }

    private func handleGlobalMouseDown() {
        let q = geometry.toQuartz(NSEvent.mouseLocation)
        for m in managed where m.phase.isPeeked {
            guard let f = m.window.frame else { continue }
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

        let trusted = AXWindow.isProcessTrusted
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
        config.save()
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.path) { _ = Config.load() }
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

    // MARK: Docking

    // Dock the frontmost window off the given edge of the desktop.
    private func dockFrontmost(_ edge: DockEdge) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard let window = AXWindow.focusedWindow(ofPID: pid) else { return }
        guard let frame = window.frame, frame.size.width > 0, frame.size.height > 0 else { return }

        if let existing = managed.first(where: { CFEqual($0.window.element, window.element) }) {
            // Re-dock to a new edge.
            existing.perp = geometry.dockPerp(for: edge, frame: frame)
            existing.dock(to: edge)
            rebuildMenu()
            return
        }

        let m = ManagedWindow(window: window, edge: edge, delegate: self)
        m.perp = geometry.dockPerp(for: edge, frame: frame)
        m.restoreFrame = frame
        managed.append(m)
        m.dock()
        rebuildMenu()
        Log.info("docked window frame=\(frame) edge=\(edge), total=\(managed.count)")
    }

    func removeManaged(_ m: ManagedWindow) {
        m.detachStrip()
        managed.removeAll { $0 === m }
        rebuildMenu()
    }

    // MARK: WindowDockDelegate

    func nameForWindow(_ window: AXWindow) -> String {
        window.title ?? "窗口"
    }

    func activate(window: AXWindow) {
        guard let pid = window.pid else { return }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    private func appIsFrontmost(_ m: ManagedWindow) -> Bool {
        guard let pid = m.window.pid else { return false }
        return pid == (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
    }

    // MARK: Poll

    private func poll() {
        guard AXWindow.isProcessTrusted else { return }
        let q = geometry.toQuartz(NSEvent.mouseLocation)
        let now = Date()
        let anyPeeked = managed.contains { $0.phase.isPeeked }
        var toRemove: [ManagedWindow] = []
        for m in managed {
            let blockedBySmaller = m.phase.isDocked && smallestDockedUnder(q, excluding: m)
            if m.evaluate(mouseQ: q, frontmost: appIsFrontmost(m),
                          blockedByPeeked: anyPeeked, blockedBySmaller: blockedBySmaller,
                          now: now) {
                toRemove.append(m)
            }
        }
        for m in toRemove { removeManaged(m) }
    }

    // True if another docked window whose sliver also sits under the cursor is
    // smaller (or equally small but earlier in the managed order) — so the
    // smallest window owns the overlap and the rest stay hidden.
    private func smallestDockedUnder(_ q: CGPoint, excluding m: ManagedWindow) -> Bool {
        guard let f = m.window.frame else { return false }
        let thisSize = geometry.sliverLength(edge: m.edge, size: f.size)
        for other in managed where other !== m && other.phase.isDocked {
            guard let of = other.window.frame else { continue }
            let sliver = geometry.sliverRect(edge: other.edge, size: of.size, perp: other.perp,
                                             sliver: config.sliverPx, fakeSliver: config.fakeSliverPx)
            guard sliver.insetBy(dx: -6, dy: -6).contains(q) else { continue }
            let otherSize = geometry.sliverLength(edge: other.edge, size: of.size)
            if otherSize < thisSize || (otherSize == thisSize && other.id < m.id) {
                return true
            }
        }
        return false
    }
}
