import AppKit

@MainActor
final class ProbeConfiguration: NSWindowController {
    private let authorize: (URL) throws -> Void
    private let status = NSTextField(wrappingLabelWithString:
        "仅用于验证独立屏保宿主。请选择本项目生成的测试素材目录，不会修改主程序素材库。")

    init(authorize: @escaping (URL) throws -> Void) {
        self.authorize = authorize
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Dynamic Wallpaper 屏保宿主验证"
        super.init(window: panel)
        status.frame = NSRect(x: 20, y: 82, width: 540, height: 90)
        panel.contentView?.addSubview(status)
        let choose = NSButton(title: "选择测试素材目录…", target: self, action: #selector(chooseDirectory))
        choose.frame = NSRect(x: 20, y: 24, width: 190, height: 32)
        panel.contentView?.addSubview(choose)
        let done = NSButton(title: "完成", target: self, action: #selector(finish))
        done.frame = NSRect(x: 466, y: 24, width: 94, height: 32)
        done.keyEquivalent = "\r"
        panel.contentView?.addSubview(done)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func chooseDirectory() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.prompt = "授权只读访问"
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let directory = picker.url else { return }
            do {
                try self.authorize(directory)
                self.status.stringValue = "书签已保存：\(directory.path)\n请重新启动屏保原型验证读取。"
            } catch {
                self.status.stringValue = "授权失败：\(error.localizedDescription)"
            }
        }
    }

    @objc private func finish() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }
}
