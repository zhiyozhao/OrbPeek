import ServiceManagement

// Runs before the app/controller exists. Providers only read status and bundle
// metadata; this path never registers a service, requests permissions or opens UI.
package enum LoginItemDiagnostic {
    package static func runIfRequested(arguments: [String], status: () -> SMAppService.Status,
                                       appPath: () -> String, write: (String) -> Void) -> Bool {
        guard arguments.contains("--login-item-status") else { return false }
        let value = status()
        let label: String
        switch value {
        case .notRegistered: label = "notRegistered"
        case .enabled: label = "enabled"
        case .requiresApproval: label = "requiresApproval"
        case .notFound: label = "notFound"
        @unknown default: label = "unknown"
        }
        write("SMAppService.mainApp.status=\(label) (\(value.rawValue))\nappPath=\(appPath())")
        return true
    }
}
