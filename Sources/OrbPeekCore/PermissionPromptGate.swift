// Rate-limits the visible shortcut feedback so a missing permission never
// turns a stuck global hotkey into repeated modal alerts.
package struct PermissionPromptGate {
    private var hasPrompted = false
    package init() {}

    package mutating func shouldPrompt() -> Bool {
        guard !hasPrompted else { return false }
        hasPrompted = true
        return true
    }
}
