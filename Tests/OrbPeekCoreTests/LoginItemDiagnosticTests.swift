import ServiceManagement
import Testing
@testable import OrbPeekCore

@Suite("read-only login item diagnostic")
struct LoginItemDiagnosticTests {
    @Test("normal launch never reads login status or app path")
    func normalLaunch() {
        let handled = LoginItemDiagnostic.runIfRequested(
            arguments: ["OrbPeek"],
            status: { Issue.record("status read during normal launch"); return .enabled },
            appPath: { Issue.record("path read during normal launch"); return "unexpected" },
            write: { _ in Issue.record("output during normal launch") })
        #expect(!handled)
    }

    @Test("diagnostic prints all status values and the exact app path", arguments: [
        (SMAppService.Status.notRegistered, "notRegistered"),
        (.enabled, "enabled"), (.requiresApproval, "requiresApproval"), (.notFound, "notFound")
    ])
    func statusOutput(status: SMAppService.Status, label: String) {
        var reads = 0
        var output: [String] = []
        let path = "/Applications/OrbPeek Test.app"
        let handled = LoginItemDiagnostic.runIfRequested(
            arguments: ["OrbPeek", "--login-item-status", "--self-test", "--show-settings"],
            status: { reads += 1; return status }, appPath: { path }, write: { output.append($0) })
        #expect(handled)
        #expect(reads == 1)
        #expect(output == ["SMAppService.mainApp.status=\(label) (\(status.rawValue))\nappPath=\(path)"])
    }
}
