import ApplicationServices
import Foundation
import OrbPeekCore

// Wraps an AXUIElement for a window with safe attribute access. All frames are
// in quartz (top-left origin) coordinates — see WindowGeometry for conversion.
// The `as!` casts below are to CoreFoundation typealiases (AXValue, AXUIElement)
// of values that AX APIs are guaranteed to return, so they cannot fail.
package final class AXWindow: WindowHandle {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    package static var isProcessTrusted: Bool { AXIsProcessTrusted() }

    // Trigger the system Accessibility permission prompt.
    package static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    package static func focusedWindow(ofPID pid: pid_t) -> AXWindow? {
        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused else { return nil }
        return AXWindow(window as! AXUIElement)
    }

    package var frame: CGRect? {
        var posV: CFTypeRef?
        var sizeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posV) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeV) == .success,
              let pv = posV, let sv = sizeV else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p),
              AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    package var position: CGPoint? {
        get {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &v) == .success,
                  let value = v else { return nil }
            var p = CGPoint.zero
            guard AXValueGetValue(value as! AXValue, .cgPoint, &p) else { return nil }
            return p
        }
        set {
            guard let p = newValue else { return }
            var copy = p
            guard let value = AXValueCreate(.cgPoint, &copy) else { return }
            let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
            if err != .success { Log.info("AXWindow position error \(err.rawValue) to \(p)") }
        }
    }

    package var isMinimized: Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &v) == .success else { return false }
        return (v as? Bool) ?? false
    }

    // Whether the owning app is hidden (Cmd+H). NSRunningApplication.isHidden
    // is unreliable/stale — read it from the AX application element instead.
    package var isAppHidden: Bool {
        guard let pid else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXHiddenAttribute as CFString, &v) == .success else { return false }
        return (v as? Bool) ?? false
    }

    package func unminimize() {
        if isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    package func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    // Bring the owning app frontmost and make this window its main window.
    // AX-level activation — reliable regardless of our own app's activation
    // state, unlike NSRunningApplication.activate which can silently no-op.
    package func activate() {
        guard let pid else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, kAXMainWindowAttribute as CFString, element)
    }

    package func isSameWindow(as other: any WindowHandle) -> Bool {
        guard let other = other as? AXWindow else { return false }
        return CFEqual(element, other.element)
    }

    var title: String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &v) == .success else { return nil }
        let t = v as? String
        return (t?.isEmpty ?? true) ? nil : t
    }

    package var pid: pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(element, &p) == .success ? p : nil
    }
}
