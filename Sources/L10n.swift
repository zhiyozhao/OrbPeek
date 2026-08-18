import Foundation

// Localized string lookup. Two hand-packaging quirks are handled here:
// 1. Our SPM resource bundle (OrbPeek_OrbPeek) must be found without the
//    generated Bundle.module accessor — for executable targets it only probes
//    the .app root, which codesign forbids (see the Package.swift note).
// 2. A manually loaded bundle's localizedString(forKey:) always uses the
//    bundle's development region (its Info.plist has no CFBundleLocalizations),
//    ignoring the user's language — so pick the .lproj ourselves and read the
//    strings table directly. Missing anything degrades to English, then keys.
enum L10n {
    static let table: [String: String] = {
        let name = "OrbPeek_OrbPeek.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        guard let url = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let bundle = Bundle(url: url) else { return [:] }
        func load(_ lang: String) -> [String: String] {
            guard let url = bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: "\(lang).lproj"),
                  let dict = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
            return dict
        }
        var table = load("en")
        if let lang = Bundle.preferredLocalizations(from: bundle.localizations,
                                                    forPreferences: Locale.preferredLanguages).first, lang != "en" {
            table.merge(load(lang)) { _, new in new }
        }
        return table
    }()
}

func tr(_ key: String) -> String {
    L10n.table[key] ?? key
}

func tr(_ key: String, _ arg: String) -> String {
    String(format: tr(key), arg)
}
