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
    @AppStorage("peekDwell") private var peekDwell = 0.15
    @AppStorage("slamVelocity") private var slamVelocity = 1200.0
    @AppStorage("touchDwell") private var touchDwell = 0.3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("通用") {
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
            section("快捷键") {
                shortcutRow("贴到屏幕左边", .dockLeft)
                shortcutRow("贴到屏幕右边", .dockRight)
                shortcutRow("贴到屏幕上边", .dockUp)
                shortcutRow("贴到屏幕下边", .dockDown)
            }
            section("触发") {
                sliderRow("悬停延迟", value: $peekDwell, in: 0.05 ... 0.5, specifier: "%.2f", unit: "秒")
                sliderRow("撞边速度阈值", value: $slamVelocity, in: 400 ... 2400, specifier: "%.0f", unit: "px/s")
                sliderRow("触摸停留", value: $touchDwell, in: 0.1 ... 1.0, specifier: "%.2f", unit: "秒")
            }
            section("外观") {
                sliderRow("悬浮条宽度", value: $sliverPx, in: 4 ... 30, specifier: "%.0f", unit: "px")
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func shortcutRow(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           specifier: String, unit: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 96, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(value.wrappedValue, specifier: specifier)\(unit)")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}
