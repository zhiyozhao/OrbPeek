import AppKit

// Deterministic demo content only. No editor chrome, spell checking, documents,
// user defaults, networking, or access to other application windows.
final class DemoDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return true
    }
}

let args = CommandLine.arguments
let english = args.contains("--language") && args.dropFirst().contains("en")
let dark = args.contains("--appearance") && args.dropFirst().contains("dark")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
let delegate = DemoDelegate()
app.delegate = delegate

let contentWidth: CGFloat = 720
let contentHeight: CGFloat = 620
let window = NSWindow(
    contentRect: NSRect(x: 100, y: 100, width: contentWidth, height: contentHeight),
    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
)
window.title = english ? "Git Cheatsheet" : "Git 速查"
window.delegate = delegate
window.contentMinSize = NSSize(width: contentWidth, height: contentHeight)
window.contentMaxSize = NSSize(width: contentWidth, height: contentHeight)

let root = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
root.wantsLayer = true
root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
window.contentView = root

func label(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat,
           font: NSFont, color: NSColor = .labelColor) {
    let view = NSTextField(frame: NSRect(x: x, y: contentHeight - top - height, width: width, height: height))
    view.stringValue = text
    view.font = font
    view.textColor = color
    view.isEditable = false
    view.isSelectable = false
    view.drawsBackground = false
    view.isBordered = false
    view.lineBreakMode = .byClipping
    view.maximumNumberOfLines = 1
    root.addSubview(view)
}

let titleFont = NSFont.systemFont(ofSize: 30, weight: .bold)
let sectionFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
let commandFont = NSFont(name: "Menlo", size: 16) ?? NSFont.userFixedPitchFont(ofSize: 16)!
let descriptionFont = NSFont.systemFont(ofSize: 16)
label(english ? "Git Cheatsheet" : "Git 速查", x: 28, top: 24, width: 650, height: 42, font: titleFont)

struct Section {
    let title: String
    let rows: [(String, String)]
}
let sections = [
    Section(title: english ? "View" : "查看", rows: [
        ("git status", english ? "Working tree changes" : "当前改动"),
        ("git log --oneline", english ? "Commit history" : "提交历史"),
        ("git diff", english ? "Unstaged changes" : "未暂存的改动"),
    ]),
    Section(title: english ? "Branches" : "分支", rows: [
        ("git switch -c <name>", english ? "Create and switch" : "新建并切换"),
        ("git branch -d <name>", english ? "Delete a branch" : "删除分支"),
    ]),
    Section(title: english ? "Undo" : "撤销", rows: [
        ("git restore <file>", english ? "Discard working tree changes" : "丢弃工作区改动"),
        ("git restore --staged <file>", english ? "Unstage" : "取消暂存"),
        ("git commit --amend", english ? "Amend the last commit" : "修改上一次提交"),
    ]),
    Section(title: english ? "Remote" : "远程", rows: [
        ("git fetch", english ? "Fetch updates" : "获取更新"),
        ("git pull --rebase", english ? "Pull and rebase" : "拉取并变基"),
        ("git push", english ? "Push" : "推送"),
    ]),
]

var top: CGFloat = 86
for section in sections {
    label(section.title, x: 28, top: top, width: 650, height: 28, font: sectionFont)
    top += 36
    for (command, description) in section.rows {
        label(command, x: 28, top: top, width: 345, height: 26, font: commandFont)
        label(description, x: 382, top: top, width: 310, height: 26, font: descriptionFont, color: .secondaryLabelColor)
        top += 30
    }
    top += 14
}

window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)
app.run()
