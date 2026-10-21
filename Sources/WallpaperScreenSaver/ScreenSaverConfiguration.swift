import AppKit
import ScreenSaverCore

private func configurationText(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle(for: ScreenSaverConfiguration.self), comment: "")
}

@MainActor
final class ScreenSaverConfiguration: NSWindowController {
    private let store: ScreenSaverBookmarkStore
    private let applicationBundleIdentifier: String
    private let status = NSTextField(wrappingLabelWithString: "")

    init(store: ScreenSaverBookmarkStore, bundle: Bundle) throws {
        guard let identifier = bundle.object(forInfoDictionaryKey: "DWApplicationBundleIdentifier") as? String,
              !identifier.isEmpty else {
            throw NSError(domain: "ScreenSaverConfiguration", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing DWApplicationBundleIdentifier in screen saver bundle"])
        }
        self.store = store
        applicationBundleIdentifier = identifier
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 230),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = configurationText("configuration.title")
        super.init(window: panel)
        status.frame = NSRect(x: 20, y: 92, width: 560, height: 110)
        status.stringValue = configurationText("configuration.description")
        panel.contentView?.addSubview(status)
        let choose = NSButton(title: configurationText("configuration.choose"), target: self, action: #selector(chooseDirectory))
        choose.frame = NSRect(x: 20, y: 28, width: 210, height: 32); panel.contentView?.addSubview(choose)
        let openApp = NSButton(title: configurationText("configuration.openApp"), target: self, action: #selector(openApplication))
        openApp.frame = NSRect(x: 240, y: 28, width: 190, height: 32); panel.contentView?.addSubview(openApp)
        let done = NSButton(title: configurationText("configuration.done"), target: self, action: #selector(finish))
        done.frame = NSRect(x: 486, y: 28, width: 94, height: 32); done.keyEquivalent = "\r"
        panel.contentView?.addSubview(done)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func chooseDirectory() {
        guard let window else { return }
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false; picker.prompt = configurationText("configuration.authorize")
        picker.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let directory = picker.url else { return }
            do {
                try self.store.authorize(directory)
                self.status.stringValue = String(format: configurationText("configuration.connected"), directory.path)
            } catch {
                self.status.stringValue = screenSaverHostFailure(capturing: error).errorDescription
                    ?? configurationText("failure.generic")
            }
        }
    }

    @objc private func openApplication() {
        guard let application = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: applicationBundleIdentifier) else {
            status.stringValue = configurationText("configuration.appMissing"); return
        }
        NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration()) {
            [weak self] _, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.status.stringValue = screenSaverHostFailure(capturing: error).errorDescription
                        ?? configurationText("failure.generic")
                }
            }
        }
    }

    @objc private func finish() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }
}
