import Cocoa
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

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
    private var managed: [ManagedWindow] = []
    private var pollTimer: Timer?
    private var settingsWindow: NSWindow?

    override init() {
        config = Config()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.title = "◉"
            button.font = NSFont.systemFont(ofSize: 12)
            button.toolTip = "OrbPeek — 把窗口贴到屏幕外,悬停边缘滑出"
        }
        rebuildMenu()
        statusItem.menu?.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched, pid=\(ProcessInfo.processInfo.processIdentifier), AX trusted=\(AXWindow.isProcessTrusted)")

        KeyboardShortcuts.onKeyDown(for: .dockLeft) { [weak self] in Task { @MainActor in self?.dockFrontmost(.left) } }
        KeyboardShortcuts.onKeyDown(for: .dockRight) { [weak self] in Task { @MainActor in self?.dockFrontmost(.right) } }
        KeyboardShortcuts.onKeyDown(for: .dockUp) { [weak self] in Task { @MainActor in self?.dockFrontmost(.up) } }
        KeyboardShortcuts.onKeyDown(for: .dockDown) { [weak self] in Task { @MainActor in self?.dockFrontmost(.down) } }

        installSignalHandlers()
        installMouseMonitors()
        capturer.prewarm()
        migrateLaunchAtLogin()

        if !AXWindow.isProcessTrusted {
            promptAccessibility()
        }

        if CommandLine.arguments.contains("--show-settings") {
            openSettings()
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // Move from the legacy hand-written LaunchAgent plist to SMAppService.
    private func migrateLaunchAtLogin() {
        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/LaunchAgents/com.orbpeek.OrbPeek.plist")
        if config.autoLaunch {
            try? SMAppService.mainApp.register()
        }
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
        alert.informativeText = "否则无法移动窗口。请在系统设置 → 隐私与安全性 → 辅助功能 中勾选 OrbPeek（若未列出,点 + 添加）。授权后重新运行 OrbPeek。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Menu

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        ])
        item.isEnabled = false
        return item
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // 权限
        menu.addItem(headerItem("权限"))
        let axOK = AXWindow.isProcessTrusted
        menu.addItem(permissionItem("辅助功能", ok: axOK, action: #selector(requestAccessibility)))
        let srOK = CGPreflightScreenCaptureAccess()
        menu.addItem(permissionItem("屏幕录制", ok: srOK, action: #selector(requestScreenRecording)))
        menu.addItem(.separator())

        // 已贴边的窗口
        menu.addItem(headerItem("已贴边的窗口"))
        if managed.isEmpty {
            let item = NSMenuItem(title: "无 — 默认 Ctrl+←/→/↑/↓ 贴边", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for m in managed {
                let item = NSMenuItem(title: "\(m.appName) — \(m.phase.isPeeked ? "已滑出" : "已贴边")", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let toggle = NSMenuItem(title: m.phase.isPeeked ? "收回" : "滑出", action: #selector(togglePeek(_:)), keyEquivalent: "")
                toggle.target = self
                toggle.representedObject = m
                sub.addItem(toggle)
                let cancel = NSMenuItem(title: "取消贴边", action: #selector(cancelWindow(_:)), keyEquivalent: "")
                cancel.target = self
                cancel.representedObject = m
                sub.addItem(cancel)
                item.submenu = sub
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let viewLog = NSMenuItem(title: "打开日志…", action: #selector(openLog), keyEquivalent: "")
        viewLog.target = self
        menu.addItem(viewLog)

        let quit = NSMenuItem(title: "退出 OrbPeek", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func permissionItem(_ title: String, ok: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "\(ok ? "✓" : "✗")  \(title)\(ok ? "" : " — 点击授权")",
                              action: ok ? nil : action, keyEquivalent: "")
        item.target = self
        item.isEnabled = !ok
        return item
    }

    @objc private func requestAccessibility() {
        AXWindow.requestTrust()
    }

    @objc private func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
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

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "OrbPeek 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 492, height: 620))
            window.center()
            settingsWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
        NSApp.activate()
    }

    @objc private func openLog() {
        Log.info("log opened")
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.path))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Docking

    // Dock the frontmost window off the given edge of the desktop.
    private func dockFrontmost(_ edge: DockEdge) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard let window = AXWindow.focusedWindow(ofPID: pid) else { return }
        guard let frame = window.frame, frame.size.width > 0, frame.size.height > 0 else { return }

        if let existing = managed.first(where: { CFEqual($0.window.element, window.element) }) {
            // Re-dock to a new edge. A still-hidden window's live frame is the
            // parked position — derive the perpendicular coordinate from the
            // original on-screen frame instead.
            let basis = existing.phase.isDocked ? existing.restoreFrame : frame
            existing.perp = geometry.dockPerp(for: edge, frame: basis)
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
        Log.info("removed managed window, total=\(managed.count)")
        rebuildMenu()
    }

    // MARK: WindowDockDelegate

    func nameForWindow(_ window: AXWindow) -> String {
        window.title ?? "窗口"
    }

    func activate(window: AXWindow) {
        guard let pid = window.pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
    }

    private func appIsFrontmost(_ m: ManagedWindow) -> Bool {
        guard let pid = m.window.pid else { return false }
        return pid == (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
    }

    // MARK: Poll

    private var launchedAt = Date()
    private var lastMouseQ: CGPoint?
    private var lastMouseAt: Date?

    private func poll() {
        guard AXWindow.isProcessTrusted else { return }
        let q = DebugMouse.location(sinceLaunch: Date().timeIntervalSince(launchedAt))
            ?? geometry.toQuartz(NSEvent.mouseLocation)
        let now = Date()
        var velocity = CGPoint.zero
        if let lastQ = lastMouseQ, let lastT = lastMouseAt {
            let dt = now.timeIntervalSince(lastT)
            if dt > 0.001 {
                velocity = CGPoint(x: (q.x - lastQ.x) / dt, y: (q.y - lastQ.y) / dt)
            }
        }
        lastMouseQ = q
        lastMouseAt = now
        let anyPeeked = managed.contains { $0.phase.isPeeked }
        var toRemove: [ManagedWindow] = []
        for m in managed {
            let blockedBySmaller = m.phase.isDocked && smallestDockedUnder(q, excluding: m)
            if m.evaluate(mouseQ: q, mouseVelocity: velocity, frontmost: appIsFrontmost(m),
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
            guard let of = other.window.frame, let oscreen = other.dockScreen(in: geometry) else { continue }
            let sliver = geometry.sliverRect(edge: other.edge, size: of.size, perp: other.perp,
                                             screen: oscreen, thickness: config.sliverPx)
            guard sliver.insetBy(dx: -6, dy: -6).contains(q) else { continue }
            let otherSize = geometry.sliverLength(edge: other.edge, size: of.size)
            if otherSize < thisSize || (otherSize == thisSize && other.id < m.id) {
                return true
            }
        }
        return false
    }
}
