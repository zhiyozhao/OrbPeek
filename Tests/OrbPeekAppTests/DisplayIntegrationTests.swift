import Foundation
import CoreGraphics
import Testing
@testable import OrbPeek

@Suite("display rule app integration")
struct DisplayIntegrationTests {
    @Test("CGSession's actual console key opens the gate and unknown data closes it")
    func consoleSession() {
        let active = SessionAvailability(snapshot: ["kCGSSessionOnConsoleKey": true, "CGSSessionScreenIsLocked": false])
        #expect(active.isActive && !active.isLocked)
        let inactive = SessionAvailability(snapshot: [kCGSessionOnConsoleKey as String: false, "CGSSessionScreenIsLocked": false])
        #expect(!inactive.isActive)
        #expect(!SessionAvailability(snapshot: nil).isActive)
        #expect(SessionAvailability(snapshot: nil).isLocked)
        #expect(!SessionAvailability(snapshot: ["kCGSessionOnConsoleKey": true]).isActive)
    }

    @Test("rescue menu has Chinese and English entries in the existing localization tables")
    func rescueTranslations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (language, title) in [("zh-Hans", "找回所有窗口"), ("en", "Bring Back All Windows")] {
            let url = root.appendingPathComponent("Sources/OrbPeek/Resources/\(language).lproj/Localizable.strings")
            let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String]
            #expect(table?["menu.rescueAll"] == title)
        }
    }
}
