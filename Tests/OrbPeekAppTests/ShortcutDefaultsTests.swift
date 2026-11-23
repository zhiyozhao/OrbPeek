import AppKit
import Foundation
import KeyboardShortcuts
import Testing
@testable import OrbPeek

@Suite("shortcut defaults", .serialized)
struct ShortcutDefaultsTests {
    @Test("new defaults preserve saved shortcuts, legacy defaults and disabled bindings")
    func defaultsPreserveSavedChoices() throws {
        // Overlay reads in this test process only. Preseed every binding before
        // accessing the app's lazy static Names: no hotkeys are registered and
        // no persistent defaults or running app settings are changed.
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }

        let customLeft = KeyboardShortcuts.Shortcut(.a, modifiers: [.option, .command])
        let legacyRight = KeyboardShortcuts.Shortcut(.rightArrow, modifiers: [.control, .shift])
        let customDown = KeyboardShortcuts.Shortcut(.f8, modifiers: [.command])
        func encoded(_ shortcut: KeyboardShortcuts.Shortcut) throws -> String {
            String(decoding: try JSONEncoder().encode(shortcut), as: UTF8.self)
        }
        let saved: [String: Any] = [
            "KeyboardShortcuts_dockLeft": try encoded(customLeft),
            "KeyboardShortcuts_dockRight": try encoded(legacyRight),
            "KeyboardShortcuts_dockUp": false,
            "KeyboardShortcuts_dockDown": try encoded(customDown),
        ]
        defaults.setVolatileDomain(previous.merging(saved) { _, value in value },
                                   forName: UserDefaults.argumentDomain)

        let bindings: [(KeyboardShortcuts.Name, String, KeyboardShortcuts.Key, KeyboardShortcuts.Shortcut?)] = [
            (.dockLeft, "dockLeft", .leftArrow, customLeft),
            (.dockRight, "dockRight", .rightArrow, legacyRight),
            (.dockUp, "dockUp", .upArrow, nil),
            (.dockDown, "dockDown", .downArrow, customDown),
        ]
        for (name, rawValue, key, savedShortcut) in bindings {
            #expect(name.rawValue == rawValue)
            #expect(name.defaultShortcut == .init(key, modifiers: [.control, .command]))
            #expect(name.shortcut == savedShortcut)
            // Recreating a Name (as happens on another launch) must also keep
            // both a user's custom shortcut and an explicitly disabled one.
            let reopened = KeyboardShortcuts.Name(rawValue, default: name.defaultShortcut)
            #expect(reopened.shortcut == savedShortcut)
        }
        #expect(defaults.object(forKey: "KeyboardShortcuts_dockUp") as? Bool == false)
    }
}
