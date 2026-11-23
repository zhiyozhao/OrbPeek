import AppKit
import Foundation
import KeyboardShortcuts
import ObjectiveC
import Testing
@testable import OrbPeek

@Suite("shortcut defaults", .serialized)
struct ShortcutDefaultsTests {
    @Test("fresh installations use Control-Command and the corresponding arrow")
    func freshInstallDefaults() throws {
        let marker = "ORBPEEK_FRESH_INSTALL_TEST"
        if ProcessInfo.processInfo.environment[marker] != "1" {
            // A fresh process also resets the app's lazy static Names.
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var arguments = Array(CommandLine.arguments.dropFirst())
            if let filter = arguments.firstIndex(of: "--filter") {
                arguments.removeSubrange(filter...min(filter + 1, arguments.count - 1))
            }
            child.arguments = arguments + ["--filter", "freshInstallDefaults"]
            var environment = ProcessInfo.processInfo.environment
            environment[marker] = "1"
            child.environment = environment
            try child.run()
            child.waitUntilExit()
            #expect(child.terminationReason == .exit)
            #expect(child.terminationStatus == 0)
            return
        }

        // Replace +standardUserDefaults only in this child, so both the app
        // and the real dependency use an empty, disposable suite. CF's home
        // override alone does not isolate preferences served by cfprefsd.
        let suite = "com.orbpeek.tests.\(UUID().uuidString)"
        let isolated = try #require(UserDefaults(suiteName: suite))
        let getter = try #require(class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)))
        let replacement = imp_implementationWithBlock({ isolated } as @convention(block) () -> UserDefaults)
        let original = method_setImplementation(getter, replacement)
        defer {
            method_setImplementation(getter, original)
            imp_removeBlock(replacement)
            isolated.removePersistentDomain(forName: suite)
        }
        let rawNames = ["dockLeft", "dockRight", "dockUp", "dockDown"]
        for rawName in rawNames {
            #expect(UserDefaults.standard.object(forKey: "KeyboardShortcuts_\(rawName)") == nil)
        }
        // No app, controller or shortcut handlers are started in this process.
        let bindings: [(KeyboardShortcuts.Name, KeyboardShortcuts.Key)] = [
            (.dockLeft, .leftArrow), (.dockRight, .rightArrow),
            (.dockUp, .upArrow), (.dockDown, .downArrow),
        ]
        for (name, key) in bindings {
            #expect(name.shortcut == .init(key, modifiers: [.control, .command]))
        }
    }

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
