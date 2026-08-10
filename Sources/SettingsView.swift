import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let dockLeft = Self("dockLeft", default: .init(.leftArrow, modifiers: [.control]))
    static let dockRight = Self("dockRight", default: .init(.rightArrow, modifiers: [.control]))
    static let dockUp = Self("dockUp", default: .init(.upArrow, modifiers: [.control]))
    static let dockDown = Self("dockDown", default: .init(.downArrow, modifiers: [.control]))
}

struct SettingsView: View {
    @AppStorage("autoLaunch") private var autoLaunch = false
    @AppStorage("sliverPx") private var sliverPx = 15.0

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机自启动", isOn: $autoLaunch)
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
            Section("快捷键") {
                LabeledContent("贴到屏幕左边") { KeyboardShortcuts.Recorder(for: .dockLeft) }
                LabeledContent("贴到屏幕右边") { KeyboardShortcuts.Recorder(for: .dockRight) }
                LabeledContent("贴到屏幕上边") { KeyboardShortcuts.Recorder(for: .dockUp) }
                LabeledContent("贴到屏幕下边") { KeyboardShortcuts.Recorder(for: .dockDown) }
            }
            Section("外观") {
                HStack {
                    Text("悬浮条宽度")
                    Slider(value: $sliverPx, in: 4 ... 30)
                    Text("\(sliverPx, specifier: "%.0f")px")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}
