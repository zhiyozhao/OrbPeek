import Testing
@testable import OrbPeekCore

@Suite("shortcut permission feedback")
struct PermissionPromptGateTests {
    @Test("missing accessibility prompts at most once per run")
    func promptsOnlyOnce() {
        var gate = PermissionPromptGate()
        let first = gate.shouldPrompt()
        let second = gate.shouldPrompt()
        let third = gate.shouldPrompt()
        #expect(first)
        #expect(!second)
        #expect(!third)
    }
}
