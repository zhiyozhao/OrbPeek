# 默认快捷键调研（2026-11-23，已确认）

用户已确认新的默认值为 **⌃⌘ + 方向键（Control + Command）**，README 和官网已统一采用。下文保留调研时的其他方案及其冲突，作为选择依据，不代表当前默认值。用户自己的 Control + 方向键仍属于个人设置。

文档与 `devs/default-shortcuts` 已一并合入 1.1.3：新安装使用 Control + Command，已经保存过的快捷键（包括旧默认和主动禁用）保持不变，不做迁移。

## 推荐和取舍

最终采用 **⌃⌘ + 方向键**，优先考虑两修饰键的易按程度。已知代价是 VS Code 集成终端分屏调整、JetBrains 相关跳转和 Diff 等冲突，用户可在 OrbPeek 设置里按需修改。

调研时曾建议 Control + Shift + Command，以避开系统 Spaces / Mission Control、标准文字选区、Rectangle / Magnet 的主要默认键和 Rectangle 跨屏键；但该组仍冲突于 VS Code 智能选择。方向键的常用两修饰键和三修饰键方案没有一个能覆盖下表所有应用。

| 组合 | 主要冲突和代价 | 判断 |
|---|---|---|
| ⌃ + 箭头 | 左右切 Space，上调度中心，下 App Exposé；全键盘控制另有相邻控件导航 | 四方向被系统占用，不采用 |
| Control + Shift + 箭头（旧默认） | VS Code 智能选区的备用键；JetBrains Mac keymap 切编辑器标签、上下方法、Diff；Excel 区域扩选和 Windows 风格/远程应用也需留意 | 不再作为新默认 |
| Control + Shift + Command + 箭头（调研方案） | VS Code 智能选区主键；第三方 keymap 和用户自定义仍需重设 | 未采用 |
| ⌃⌘ + 箭头（已确认的新默认） | VS Code 集成终端左右调分屏宽；JetBrains 相关符号跳转、Diff 应用修改；Finder ⌃⌘↑ 在新窗口打开上级目录 | 优先易按，接受这些冲突 |
| ⌃⌥⌘ + 箭头（备选二） | Rectangle 左右跨显示器；VoiceOver 的 VO+Command 扩展导航 | 多屏用户不推荐 |
| ⌃⌥⇧⌘ + 箭头（备选三 / Hyper） | 四修饰键难按，Caps Lock 映射需另配；VoiceOver 及自定义映射仍非绝对空闲 | 更适合已有 Hyper 的进阶用户 |

其他常见候选也不空闲：⌃⌥ 箭头被 Rectangle / Magnet 半屏占用，也是 VoiceOver 默认导航；⌃⌥⇧ 箭头在 Rectangle 有最大高度/缩小/放大，在 VoiceOver 有开始/停止交互。⌥⌘ 箭头在浏览器和终端中用途广。

## 按范围核对

- **macOS 系统**：⌃←/→ Spaces、⌃↑ Mission Control、⌃↓ Application windows。macOS 15+ 平铺窗口是 **Fn**+⌃箭头，多窗口排列含 Fn + Control + Shift + 箭头；不要漏写 Fn 后误判为同一组合。
- **输入法**：常见切换为 ⌃Space / ⌃⌥Space，未发现占用已选四键的通用默认；具体输入法可另有自定义。
- **辅助功能**：VoiceOver 默认 VO 为 ⌃⌥ 或 Caps Lock，VO+箭头导航，VO+⇧↑/↓ 开始/停止交互。含 ⌃⌥ 的高修饰键组合不能简单宣布“空闲”。常规缩放、辅助功能开关并不占推荐组。
- **文本选择**：Mac 常规是 ⇧箭头按字/行选择，⌥⇧箭头按词/段，⌘⇧箭头到行/文档边界。不能把 Windows 的 Control + Shift 选词套到所有 Mac 文本框；Office、Web 编辑器、远程会话和 Windows 风格 keymap 另论。
- **Rectangle / Magnet / Raycast**：Rectangle 推荐默认和 Magnet 主默认使用 ⌃⌥箭头做半屏。Rectangle 的 ⌃⌥⌘←/→ 跨屏；⌃⌥⇧↑ 最大高度，←/→ 缩小/放大。Spectacle 兼容方案另有 ⌥⌘箭头。Raycast 窗口命令支持自行设快捷键和 preset，不应把某个用户配置说成所有安装的出厂值。
- **Safari / Chrome**：⌥⌘←/→ 切标签；Chrome ⌥⌘↑/↓ 切工具栏焦点。浏览器文本框遵循文本选择键位。
- **VS Code**：Control + Shift + Command + 左右箭头为智能选区主键，Control + Shift + 左右箭头为备用；⌃⌘←/→ 为终端分屏宽度。已确认的新默认会与后者冲突。
- **JetBrains**：Mac OS X 10.5+ keymap 源码中 Control + Shift + 左右箭头为 Previous/NextEditorTab，也用于 Diff 跳变化；Control + Shift + 上下箭头为 MethodUp/Down，下箭头另有 ShowContent。⌃⌘↑ GotoRelated，⌃⌘←/→ Diff ApplyRight/LeftSide；⌃⌥箭头调整工具窗。不同 keymap 可不同。
- **Terminal / iTerm**：Terminal ⌥⌘↑/↓ 跳书签，⌘↑/↓ 跳标记，⌘⇧↑/↓ alternate screen；iTerm ⌥⌘箭头切分屏。Shell、tmux、远程 Vim 还有用户级绑定，无法保证全部无冲突。
- **Office**：Word 的 Mac 选词主要是 ⌥⇧左右，⌘⇧箭头扩展到行/段边界；Excel 也接受 Control/Command+Shift+箭头扩展数据区域。没有把 Windows 版快捷键整段当成 Mac 默认。

## 代码位置和修改能力

- `Sources/OrbPeek/SettingsView.swift` 四个 `KeyboardShortcuts.Name` 默认 `.control, .command`。
- 同文件设置页四个 `KeyboardShortcuts.Recorder` 可分别改键，`OrbPeekController` 绑定四个 name；快捷键库保存用户设置。
- 仅四个设置键不存在时使用新默认；不覆盖任何已保存值，包括用户录入的 ⌃箭头、旧默认或禁用状态。

## 证据

1. [Apple 系统快捷键与文本选择](https://support.apple.com/en-us/102650)、[Spaces](https://support.apple.com/guide/mac-help/work-in-multiple-spaces-mh14112/mac)、[窗口平铺（含 Fn）](https://support.apple.com/guide/mac-help/mac-window-tiling-icons-keyboard-shortcuts-mchl9674d0b0/mac)。
2. [VoiceOver 交互指令](https://support.apple.com/guide/voiceover/interaction-commands-cpvokys07/mac)、[VoiceOver 文本选择与 VO 定义](https://support.apple.com/guide/voiceover/select-text-mchlp2741/mac)。
3. [Rectangle 快捷键源码（default / spectacle）](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/WindowAction/WindowAction.swift)。[Magnet 官网](https://magnet.crowdcafe.com/)说明支持自定义，但未列完整键表；主默认由[产品介绍](https://thesweetsetup.com/magnet-brings-windows-10-style-window-management-to-macos/)交叉核对，未声称所有版本/其他键穷尽。
4. [Raycast 窗口管理设置和 presets](https://manual.raycast.com/window-management)。
5. [Chrome Mac 快捷键](https://support.google.com/chrome/answer/157179)、[Safari 快捷键](https://support.apple.com/guide/safari/keyboard-and-other-shortcuts-cpsh003/mac)。
6. [VS Code Mac 键表](https://code.visualstudio.com/shortcuts/keyboard-shortcuts-macos.pdf)、[智能选区源码（含备用键）](https://github.com/microsoft/vscode/blob/main/src/vs/editor/contrib/smartSelect/browser/smartSelect.ts)、[集成终端](https://code.visualstudio.com/docs/terminal/basics)。
7. [JetBrains Mac keymap 源码](https://github.com/JetBrains/intellij-community/blob/master/platform/platform-resources/src/keymaps/Mac%20OS%20X%2010.5%2B.xml)；仅引用 Mac 段落，没有把父级 Windows 默认整体当成 Mac。
8. [Terminal 快捷键](https://support.apple.com/guide/terminal/keyboard-shortcuts-trmlshtcts/mac)、[iTerm 分屏键位](https://iterm2.com/documentation/2.1/documentation-general-usage.html)；iTerm 引用为版本化文档，用户配置可能不同。
9. [Word 官方跨平台键表（按 Mac 段核对）](https://support.microsoft.com/en-gb/accessibility/word/keyboard-shortcuts-in-word)、[Excel 官方键表](https://support.microsoft.com/en-us/office/keyboard-shortcuts-in-excel-1798d9d5-842a-42b8-9c99-9b7213f0040f)。

调研阶段只读公开文档与仓库源码。本次按已确认的选择更新文档和截图，未调用系统快捷键、读取用户设置、改动用户快捷键或运行权限请求。
