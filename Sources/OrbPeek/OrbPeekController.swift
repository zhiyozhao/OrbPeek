import Cocoa
import KeyboardShortcuts
import OrbPeekCore
import ServiceManagement
import SwiftUI

@MainActor
@main
final class OrbPeekController: NSObject, NSApplicationDelegate, NSMenuDelegate, WindowDockDelegate {
    static func main() {
        if LoginItemDiagnostic.runIfRequested(
            arguments: CommandLine.arguments,
            status: { SMAppService.mainApp.status },
            appPath: { Bundle.main.bundleURL.path }, write: { print($0) }) {
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
        }
        let app = NSApplication.shared
        let controller = OrbPeekController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var settings: Config
    package var config: DockConfiguration { settings.dockConfiguration }
    package let geometry = WindowGeometry()
    private let captureEngine = SliceCapturer()
    package var capturer: any SliceCapturing { captureEngine }
    package var offlinePolicy: DockSessionOptions.OfflinePolicy { .releaseToVisible }

    private let statusItem: NSStatusItem
    private lazy var session = DockSession(delegate: self)
    private var managed: [ManagedWindow] { session.windows }
    private let dockStateStore = DockStateStore()
    private var recoveryPending = true
    private var recoveryDeferralLogged = false
    private var pollTimer: Timer?
    private var settingsWindow: NSWindow?
    private var shortcutPermissionPrompt = PermissionPromptGate()

    override init() {
        settings = Config()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            // The "slit" mark from the asset catalog (Scripts/make-icon.swift
            // is the single source for all icon assets); the imageset is
            // marked template in the catalog, so dark menu bars auto-invert.
            button.image = NSImage(named: "MenuIcon")
        }
        rebuildMenu()
        statusItem.menu?.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launched, pid=\(ProcessInfo.processInfo.processIdentifier), AX trusted=\(AXWindow.isProcessTrusted)")
        recoverOrphanedWindowsIfPossible()

        KeyboardShortcuts.onKeyDown(for: .dockLeft) { [weak self] in Task { @MainActor in self?.dockFrontmost(.left) } }
        KeyboardShortcuts.onKeyDown(for: .dockRight) { [weak self] in Task { @MainActor in self?.dockFrontmost(.right) } }
        KeyboardShortcuts.onKeyDown(for: .dockUp) { [weak self] in Task { @MainActor in self?.dockFrontmost(.up) } }
        KeyboardShortcuts.onKeyDown(for: .dockDown) { [weak self] in Task { @MainActor in self?.dockFrontmost(.down) } }

        installSignalHandlers()
        installMouseMonitors()
        installSettleObservers()
        installSessionGate()
        installMainMenu()
        captureEngine.prewarm()
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
        if settings.autoLaunch {
            try? SMAppService.mainApp.register()
        }
    }

    // A minimal main menu so standard shortcuts work while the settings
    // window is key: ⌘W closes it, ⌘Q quits. Without a main menu these keys
    // route nowhere.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: tr("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: tr("menu.window"))
        windowMenu.addItem(withTitle: tr("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
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
                m.beginGesture(at: q)
            } else {
                m.stopActivationRetry()
            }
        }
    }

    private func handleGlobalMouseUp() {
        for m in managed where m.gesture {
            m.endGesture()
        }
    }

    // Display (un)plug shuffles window frames behind our back — and the parked
    // position itself moves when the desktop frame changes. (Sleep/lock needs
    // nothing: macOS preserves frames, and all dock geometry is a pure
    // function of the current screen set, so nothing moves.) For a few
    // seconds after a screen change, "settling" suppresses the external-move
    // release: managed windows are re-anchored to their recomputed positions
    // instead of being dropped where macOS left them.

    private func installSettleObservers() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context else { return }
            Task { @MainActor in
                let controller = Unmanaged<OrbPeekController>.fromOpaque(context).takeUnretainedValue()
                // kCGDisplayBeginConfigurationFlag (the C constant is not imported).
                if flags.contains(CGDisplayChangeSummaryFlags(rawValue: 1 << 0)) {
                    controller.session.settling.displayReconfigurationBegan(at: Date())
                    controller.logLayout("display reconfiguration begin")
                } else {
                    controller.session.settling.displayReconfigurationEnded(at: Date())
                    controller.logLayout("display reconfiguration end")
                }
            }
        }, context)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: nil
        ) { _ in
            Task { @MainActor in
                (NSApplication.shared.delegate as? OrbPeekController)?.session.settling.screenParametersChanged(at: Date())
                (NSApplication.shared.delegate as? OrbPeekController)?.logLayout("screen parameters changed")
            }
        }
    }

    // AX calls black out while the screen is locked: every attribute read and
    // set fails (kAXErrorInvalidUIElement/-25202 etc.). Polling through the
    // blackout misreads it as "window closed" and drops managed windows —
    // with the restore sets failing too, leaving them parked off-screen.
    // Gate instead: freeze evaluation while locked (macOS preserves frames
    // across lock, so there is genuinely nothing to do). Same approach as
    // AltTab's ScreenLockEvents.
    private var screenLocked: Bool { session.screenLocked }

    private func installSessionGate() {
        let dnc = DistributedNotificationCenter.default()
        // .deliverImmediately matters: we are an accessory app and inactive
        // while locked — suspended delivery would drop the notification.
        dnc.addObserver(self, selector: #selector(handleScreenLocked),
                        name: .init("com.apple.screenIsLocked"), object: nil,
                        suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(handleScreenUnlocked),
                        name: .init("com.apple.screenIsUnlocked"), object: nil,
                        suspensionBehavior: .deliverImmediately)
        // Re-seed on wake: the unlock notification can be lost across deep
        // sleep. The initial seed covers launching while already locked.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            Task { @MainActor in
                if let controller = NSApplication.shared.delegate as? OrbPeekController {
                    controller.session.settling.didWake(at: Date())
                    controller.logLayout("wake")
                    controller.reseedLockState()
                }
            }
        }
        reseedLockState()
    }

    @objc private nonisolated func handleScreenLocked() {
        Task { @MainActor in
            self.session.lock()
            Log.info("screen locked, poll frozen")
        }
    }

    @objc private nonisolated func handleScreenUnlocked() {
        Task { @MainActor in
            self.session.unlock()
            self.logLayout("screen unlocked")
        }
    }

    private func reseedLockState() {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        if (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false { session.lock() }
        else { session.unlock() }
    }

    func restoreAll() {
        Log.info("signal restore begin count=\(managed.count)")
        let exited = session.quit()
        persistDockedWindows(cleanExit: true, exitedAt: Date(), windows: exited)
        session.clearPending()
        rebuildMenu()
        Log.info("restored all docked windows on signal")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("quit restore begin count=\(managed.count)")
        let exited = session.quit()
        persistDockedWindows(cleanExit: true, exitedAt: Date(), windows: exited)
        session.clearPending()
        Log.info("quit restore complete; terminated")
    }

    private func promptAccessibility() {
        let alert = NSAlert()
        alert.messageText = tr("alert.axTitle")
        alert.informativeText = tr("alert.axMessage")
        alert.addButton(withTitle: tr("alert.openSettings"))
        alert.addButton(withTitle: tr("alert.later"))
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
        menu.addItem(headerItem(tr("menu.permissions")))
        let axOK = AXWindow.isProcessTrusted
        menu.addItem(permissionItem(tr("menu.accessibility"), ok: axOK, action: #selector(requestAccessibility)))
        let srOK = CGPreflightScreenCaptureAccess()
        menu.addItem(permissionItem(tr("menu.screenRecording"), ok: srOK, action: #selector(requestScreenRecording)))
        menu.addItem(.separator())

        // 已贴边的窗口
        if !managed.isEmpty {
            menu.addItem(headerItem(tr("menu.undockHint")))
            // App name, numbered when several windows of the same app are docked.
            var totals: [String: Int] = [:]
            for m in managed { totals[m.appName, default: 0] += 1 }
            var seen: [String: Int] = [:]
            for m in managed {
                let base = m.appName
                seen[base, default: 0] += 1
                let title = (totals[base] ?? 1) > 1 ? "\(base) \(seen[base]!)" : base
                let item = NSMenuItem(title: title, action: #selector(cancelWindow(_:)), keyEquivalent: "")
                item.representedObject = m
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: tr("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let viewLog = NSMenuItem(title: tr("menu.openLog"), action: #selector(openLog), keyEquivalent: "")
        viewLog.target = self
        menu.addItem(viewLog)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let versionItem = NSMenuItem(title: tr("menu.version", version), action: #selector(openReleases), keyEquivalent: "")
        versionItem.target = self
        menu.addItem(versionItem)

        let quit = NSMenuItem(title: tr("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func permissionItem(_ title: String, ok: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: ok ? title : tr("menu.grant", title),
                              action: ok ? nil : action, keyEquivalent: "")
        item.target = self
        item.isEnabled = !ok
        item.image = NSImage(systemSymbolName: ok ? "checkmark.circle" : "xmark.circle",
                             accessibilityDescription: title)
        return item
    }

    @objc private func requestAccessibility() {
        AXWindow.requestTrust()
    }

    @objc private func requestScreenRecording() {
        let alert = NSAlert()
        alert.messageText = tr("alert.screenTitle")
        alert.informativeText = tr("alert.screenMessage")
        alert.addButton(withTitle: tr("alert.continue"))
        alert.addButton(withTitle: tr("alert.later"))
        if alert.runModal() == .alertFirstButtonReturn {
            CGRequestScreenCaptureAccess()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: Actions

    @objc private func cancelWindow(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? ManagedWindow else { return }
        m.terminate(exit: .restore)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = tr("settings.windowTitle")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Settings windows are opaque with the standard background —
            // otherwise the desktop wallpaper bleeds through and warms the color.
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            // Size the window to the content — a hardcoded height that is
            // slightly short gives the Form a useless barely-scrollable bar.
            window.setContentSize(hosting.view.fittingSize)
            window.center()
            settingsWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                Task { @MainActor in
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        // Front the window reliably: the macOS 14+ parameterless activate()
        // can silently DECLINE to activate an accessory app (window then opens
        // behind whatever is frontmost). activate(ignoringOtherApps:) is
        // deprecated but is the only reliable call for menu-bar apps, and is
        // appropriate here — the user explicitly clicked Settings.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    @objc private func openLog() {
        Log.info("log opened")
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.path))
    }

    @objc private func openReleases() {
        NSWorkspace.shared.open(URL(string: "https://github.com/zhiyozhao/OrbPeek/releases")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Docking

    private func makeManagedWindow(_ window: any WindowHandle, edge: DockEdge) -> ManagedWindow {
        return session.add(window: window, edge: edge) { managedWindow in
            managedWindow.log = { [weak managedWindow] message in
                guard let managedWindow else { return }
                let app = managedWindow.window.bundleIdentifier ?? "unknown"
                let wid = managedWindow.windowID.map(String.init) ?? "pending"
                Log.info("[win=\(managedWindow.id.uuidString.prefix(6)) app=\(app) wid=\(wid)] \(message)")
            }
            if let axWindow = window as? AXWindow {
                axWindow.log = { message in managedWindow.log(message) }
            }
        }
    }

    // Dock the frontmost window off the given edge of the desktop.
    private func dockFrontmost(_ edge: DockEdge) {
        guard AXWindow.isProcessTrusted else {
            if shortcutPermissionPrompt.shouldPrompt() { promptAccessibility() }
            return
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard let window = AXWindow.focusedWindow(ofPID: pid) else { return }
        session.cancelPending(for: window)
        guard let frame = window.frame, frame.size.width > 0, frame.size.height > 0 else { return }

        if let existing = managed.first(where: { $0.window.isSameWindow(as: window) }) {
            // Re-dock to a new edge. The reference frame is always the
            // original pre-dock frame — never the transient peek/park position
            // — so the perpendicular coordinate stays anchored to where the
            // window was before docking, no matter how edges are switched.
            existing.redock(to: edge)
            rebuildMenu()
            return
        }

        _ = makeManagedWindow(window, edge: edge)
        rebuildMenu()
        Log.info("docked window frame=\(frame) edge=\(edge), total=\(managed.count)")
    }

    package func offlineWindowReleased(_ managedWindow: ManagedWindow) {
        session.deferPending(managedWindow)
    }

    package func removeManaged(_ m: ManagedWindow) {
        m.detachStrip()
        if let wid = m.windowID { captureEngine.evict(wid) }
        session.remove(m)
        Log.info("removed managed window, total=\(managed.count)")
        persistDockedWindows()
        rebuildMenu()
    }

    private func persistDockedWindows(cleanExit: Bool = false, exitedAt: Date? = nil,
                                      windows: [ManagedWindow]? = nil) {
        let records = (windows ?? managed).compactMap { $0.persistenceRecord(cleanExit: cleanExit, exitedAt: exitedAt) }
        do {
            if records.isEmpty { try dockStateStore.clear() }
            else { try dockStateStore.save(records) }
        } catch {
            Log.info("dock state persistence failed: \(error.localizedDescription)")
        }
    }

    private func clearDockState() {
        do { try dockStateStore.clear() }
        catch { Log.info("dock state clear failed: \(error.localizedDescription)") }
    }

    private func logLayout(_ reason: String) {
        let description = geometry.layout.screens.map {
            "id=\($0.id) frame=\($0.frame) visible=\($0.visibleFrame)"
        }.joined(separator: " | ")
        Log.info("\(reason); layout \(description)")
    }

    private func recoverOrphanedWindowsIfPossible() {
        guard recoveryPending else { return }
        guard AXWindow.isProcessTrusted else {
            if !recoveryDeferralLogged {
                recoveryDeferralLogged = true
                Log.info("launch recovery deferred: AX unavailable")
            }
            return
        }
        recoveryPending = false
        Log.info("launch recovery begin")
        DockRecovery(store: dockStateStore, redockAfterUpgrade: true, log: Log.info).recover(
            geometry: geometry,
            resolver: { [weak self] record in self?.windowsForRecovery(record) ?? [] },
            onRedock: { [weak self] record, window in self?.redockRecoveredWindow(record, window: window) }
        )
    }

    private func redockRecoveredWindow(_ record: DockedWindowRecord, window: any WindowHandle) {
        _ = makeManagedWindow(window, edge: record.edge)
        rebuildMenu()
    }

    private func windowsForRecovery(_ record: DockedWindowRecord) -> [any WindowHandle] {
        let application: NSRunningApplication?
        if let bundleID = record.bundleIdentifier {
            application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        } else {
            application = NSRunningApplication(processIdentifier: record.processID)
        }
        guard let application else { return [] }
        if let expectedBundle = record.bundleIdentifier, application.bundleIdentifier != expectedBundle { return [] }
        return AXWindow.allWindows(ofPID: application.processIdentifier)
    }

    // MARK: WindowDockDelegate

    package func dockStateDidChange() {
        persistDockedWindows()
    }

    package func makeStrip() -> any SnapshotStripHandling {
        SnapshotStrip()
    }

    package func nameForWindow(_ window: any WindowHandle) -> String {
        // The app's display name — window titles get long and noisy.
        guard let pid = window.pid,
              let name = NSRunningApplication(processIdentifier: pid)?.localizedName,
              !name.isEmpty else { return "窗口" }
        return name
    }

    package func activate(window: any WindowHandle) {
        window.raise()
        window.activate()
    }

    package func isFrontmost(_ window: any WindowHandle) -> Bool {
        guard let pid = window.pid else { return false }
        return pid == (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
    }

    func isAppHidden(_ window: AXWindow) -> Bool {
        window.isAppHidden
    }

    private func appIsFrontmost(_ m: ManagedWindow) -> Bool {
        isFrontmost(m.window)
    }

    // MARK: Poll

    private var launchedAt = Date()
    private var lastMouseQ: CGPoint?
    private var lastMouseAt: Date?

    private func poll() {
        if recoveryPending && AXWindow.isProcessTrusted { recoverOrphanedWindowsIfPossible() }
        guard AXWindow.isProcessTrusted, !screenLocked else { return }
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
        session.poll(mouseQ: q, mouseVelocity: velocity) { [weak self] in
            self?.closerDockedUnder(q, excluding: $0) ?? false
        }
        // While a window is peeked it is raised to the front — drop the strips
        // to normal level so they can't cover it; restore floating after.
        let anyPeeked = managed.contains { $0.phase.isPeeked }
        for m in managed { m.setStripFloating(!anyPeeked) }
    }

    // True if another docked window whose strip also sits under the cursor has
    // its strip CENTER closer to the cursor — the strip you aim at wins on
    // overlap (ties keep a stable order via UUID).
    private func closerDockedUnder(_ q: CGPoint, excluding m: ManagedWindow) -> Bool {
        guard let f = m.window.frame, let mscreen = m.dockScreen(in: geometry) else { return false }
        let mRect = geometry.sliverRect(edge: m.edge, size: f.size, perp: m.perp,
                                        screen: mscreen, thickness: config.sliverPx)
        let mDist = m.edge.slideAxis == .horizontal ? abs(q.y - mRect.midY) : abs(q.x - mRect.midX)
        for other in managed where other !== m && other.phase.isDocked {
            guard let of = other.window.frame, let oscreen = other.dockScreen(in: geometry) else { continue }
            let oRect = geometry.sliverRect(edge: other.edge, size: of.size, perp: other.perp,
                                            screen: oscreen, thickness: config.sliverPx)
            guard oRect.insetBy(dx: -6, dy: -6).contains(q) else { continue }
            let oDist = other.edge.slideAxis == .horizontal ? abs(q.y - oRect.midY) : abs(q.x - oRect.midX)
            if oDist < mDist || (oDist == mDist && other.id < m.id) {
                return true
            }
        }
        return false
    }
}
