import AppKit
import WallpaperCore
import WallpaperEditorCore

extension EditorApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !terminating else { show(WallpaperError("Editor is quitting")); return }
        pendingEditorURLs += urls; receivePendingEditorURLs()
    }
    func receivePendingEditorURLs() {
        guard store != nil, !pendingEditorURLs.isEmpty, !receivingEditorURLs else { return }
        receivingEditorURLs = true
        Task { @MainActor in
            defer { receivingEditorURLs = false }
            while !pendingEditorURLs.isEmpty {
                let url = pendingEditorURLs.removeFirst()
                do { try await receive(url) } catch { show(error,window:active?.window) }
            }
        }
    }
    private func receive(_ url: URL) async throws {
        guard case .openEditor(let project,let descriptor) = try EditorLink(url:url) else { throw WallpaperError("Unsupported Editor action") }
        if let descriptor {
            let exchange = try await Task.detached { try EditorExchange.read(from:descriptor) }.value
            sharedSceneOffers = exchange.scenes; sharedHostIdentifier = exchange.hostBundleIdentifier
        }
        if let project { try await openSharedProject(project) }
        else { _ = applicationShouldHandleReopen(NSApp,hasVisibleWindows:false) }
        NSApp.activate(ignoringOtherApps:true)
    }
    private func openSharedProject(_ project: SceneProjectReference) async throws {
        let key = try EditorLink.openEditor(project:project,descriptor:nil).url().absoluteString
        if let id = importedSources[key] { try await present(store.open(id:id)); return }
        let owned = try await store.importProject(root:project.root,expected:project)
        importedSources[key] = owned.document.id
        try await present(owned)
    }
    @objc func importSharedScene() {
        let offers = sharedSceneOffers
        guard !offers.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = text("chooseScene"); alert.addButton(withTitle:text("import")); alert.addButton(withTitle:text("cancel"))
        let choices = NSPopUpButton(frame:NSRect(x:0,y:0,width:360,height:30))
        choices.addItems(withTitles:offers.map(\.title)); alert.accessoryView = choices
        guard alert.runModal() == .alertFirstButtonReturn, offers.indices.contains(choices.indexOfSelectedItem) else { return }
        let project = offers[choices.indexOfSelectedItem].project
        Task { do { try await openSharedProject(project) } catch { show(error,window:active?.window) } }
    }
    @objc func openInWallpaper() {
        guard let controller = active else { return }
        let identifier: String
        if let sharedHostIdentifier { identifier = sharedHostIdentifier }
        else if let configured = Bundle.main.object(forInfoDictionaryKey:"DWHostBundleIdentifier") as? String { identifier = configured }
        else { show(WallpaperError("Host application metadata is missing"),window:controller.window); return }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier:identifier) else {
            let alert = NSAlert(); alert.messageText = text("mainMissing"); alert.addButton(withTitle:text("downloadMain")); alert.addButton(withTitle:text("cancel"))
            if alert.runModal() == .alertFirstButtonReturn,
               !NSWorkspace.shared.open(URL(string:"https://github.com/Seraph-x/Dynamic-Wallpapers/releases")!) { show(WallpaperError("Could not open the download page"),window:controller.window) }
            return
        }
        guard let bundle = Bundle(url:application), bundle.bundleIdentifier == identifier,
              bundle.object(forInfoDictionaryKey:"DWEditorExchangeAPI") as? String == "1" else { show(WallpaperError(text("invalidMain")),window:controller.window); return }
        controller.perform { controller in
            let snapshot = try await controller.materializeHandoff()
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            _ = try await NSWorkspace.shared.open([EditorLink.importScene(snapshot).url()],withApplicationAt:application,configuration:configuration)
        }
    }
}

extension EditorWindowController {
    func materializeHandoff() async throws -> SceneProjectReference {
        try await save()
        return try await materializeSavedHandoff()
    }
}
