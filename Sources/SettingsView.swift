import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let dockLeft = Self("dockLeft", default: .init(.leftArrow, modifiers: [.control, .shift]))
    static let dockRight = Self("dockRight", default: .init(.rightArrow, modifiers: [.control, .shift]))
    static let dockUp = Self("dockUp", default: .init(.upArrow, modifiers: [.control, .shift]))
    static let dockDown = Self("dockDown", default: .init(.downArrow, modifiers: [.control, .shift]))
}

struct SettingsView: View {
    @AppStorage("autoLaunch") private var autoLaunch = false
    @AppStorage("sliverPx") private var sliverPx = 15.0
    @AppStorage("stripOpacity") private var stripOpacity = 1.0

    var body: some View {
        Form {
            Section(tr("settings.general")) {
                Toggle(tr("settings.launchAtLogin"), isOn: $autoLaunch)
                    .onChange(of: autoLaunch) {
                        do {
                            if autoLaunch {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            Log.info("launch-at-login: \(error.localizedDescription)")
                        }
                    }
            }
            Section(tr("settings.shortcuts")) {
                LabeledContent(tr("settings.dockLeft")) { KeyboardShortcuts.Recorder(for: .dockLeft) }
                LabeledContent(tr("settings.dockRight")) { KeyboardShortcuts.Recorder(for: .dockRight) }
                LabeledContent(tr("settings.dockUp")) { KeyboardShortcuts.Recorder(for: .dockUp) }
                LabeledContent(tr("settings.dockDown")) { KeyboardShortcuts.Recorder(for: .dockDown) }
            }
            Section(tr("settings.appearance")) {
                HStack {
                    Text(tr("settings.stripWidth"))
                    Slider(value: $sliverPx, in: 5 ... 50).controlSize(.small)
                    Text("\(sliverPx, specifier: "%.0f")px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text(tr("settings.stripOpacity"))
                    Slider(value: $stripOpacity, in: 0.2 ... 1.0).controlSize(.small)
                    Text("\(Int(stripOpacity * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
