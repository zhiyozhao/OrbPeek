import CoreGraphics
import Foundation

struct Config {
    var autoLaunch: Bool = false
    // Margin around the window treated as "inside" so resize/edge interactions
    // don't falsely dismiss a peeked window.
    var edgeBuffer: CGFloat = 12
    // Visible slice of a docked window — the "handle" you hover to peek it.
    var sliverPx: CGFloat = 6
    // Hover dwell on the sliver before the window slides in (avoids accidental peeks).
    var peekDwell: Double = 0.15
    // Dwell inside the peeked window before leaving counts as "used it, left".
    var touchDwell: Double = 0.3
    // Dragging the peeked window this far off its docked edge cancels the dock.
    var dockCancelPx: CGFloat = 40
    // Thickness of the fake snapshot sliver used for up/down docks (macOS won't
    // let a titled window leave the top/bottom, so those edges use a captured
    // slice of the window as the handle).
    var fakeSliverPx: CGFloat = 10

    static let dir = NSHomeDirectory() + "/.config/orbpeek"
    static let path = dir + "/config.json"
    private static let url = URL(fileURLWithPath: path)

    // Reads the config file, falling back to defaults per-key (so an old or
    // hand-edited file with missing keys keeps its other values). Writes the
    // file only when it is missing or unreadable.
    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            c.save()
            return c
        }
        c.apply(json: json)
        return c
    }

    private mutating func apply(json: [String: Any]) {
        if let v = json["autoLaunch"] as? Bool { autoLaunch = v }
        if let v = num(json, "edgeBuffer") { edgeBuffer = CGFloat(v) }
        if let v = num(json, "sliverPx") { sliverPx = CGFloat(v) }
        if let v = num(json, "peekDwell") { peekDwell = v }
        if let v = num(json, "touchDwell") { touchDwell = v }
        if let v = num(json, "dockCancelPx") { dockCancelPx = CGFloat(v) }
        if let v = num(json, "fakeSliverPx") { fakeSliverPx = CGFloat(v) }
    }

    private func num(_ json: [String: Any], _ key: String) -> Double? {
        (json[key] as? NSNumber)?.doubleValue
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "autoLaunch": autoLaunch, "edgeBuffer": edgeBuffer,
            "sliverPx": sliverPx, "peekDwell": peekDwell, "touchDwell": touchDwell,
            "dockCancelPx": dockCancelPx, "fakeSliverPx": fakeSliverPx,
        ]
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: Self.url)
    }
}
