import Foundation

// App settings, backed by UserDefaults so the settings UI applies live.
// A one-time migration imports the legacy ~/.config/orbpeek/config.json.
@MainActor
final class Config {
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "autoLaunch": false,
            "edgeBuffer": 12.0,
            "sliverPx": 15.0,
            "peekDwell": 0.15,
            "touchDwell": 0.3,
            "dockCancelPx": 40.0,
            "slamVelocity": 1200.0,
            "stripOpacity": 0.5,
        ])
        migrateJSONIfNeeded()
    }

    var autoLaunch: Bool {
        get { defaults.bool(forKey: "autoLaunch") }
        set { defaults.set(newValue, forKey: "autoLaunch") }
    }

    // Margin around the window treated as "inside" so resize/edge interactions
    // don't falsely dismiss a peeked window.
    var edgeBuffer: CGFloat { CGFloat(defaults.double(forKey: "edgeBuffer")) }
    // Visible slice of a docked window — the "handle" you hover to peek it.
    var sliverPx: CGFloat { CGFloat(defaults.double(forKey: "sliverPx")) }
    // Hover dwell on the sliver before the window slides in (avoids accidental peeks).
    var peekDwell: Double { defaults.double(forKey: "peekDwell") }
    // Dwell inside the peeked window before leaving counts as "used it, left".
    var touchDwell: Double { defaults.double(forKey: "touchDwell") }
    // Dragging the peeked window this far off its docked edge cancels the dock.
    var dockCancelPx: CGFloat { CGFloat(defaults.double(forKey: "dockCancelPx")) }
    // Mouse speed (px/s toward the dock edge) above which a hover is treated
    // as a deliberate slam — peek instantly, skipping the dwell.
    var slamVelocity: Double { defaults.double(forKey: "slamVelocity") }
    // Opacity of the docked-window strip handle.
    var stripOpacity: Double { defaults.double(forKey: "stripOpacity") }

    private func migrateJSONIfNeeded() {
        let path = NSHomeDirectory() + "/.config/orbpeek/config.json"
        guard !defaults.bool(forKey: "didMigrateJSONConfig"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        for (key, value) in json where value is NSNumber {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "didMigrateJSONConfig")
        Log.info("migrated settings from config.json")
    }
}
