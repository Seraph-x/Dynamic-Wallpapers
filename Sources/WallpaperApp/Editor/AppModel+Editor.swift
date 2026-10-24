import AppKit
import WallpaperCore

extension AppModel {
    func openEditor(using suppliedLauncher: EditorLauncher? = nil) async throws {
        guard !isShuttingDown else { throw WallpaperError("应用正在退出，无法打开 Editor。") }
        let offers = library.media.compactMap { item -> EditorSceneOffer? in
            guard let project = item.sceneProject else { return nil }
            return EditorSceneOffer(id:item.id,title:item.name,project:project)
        }
        let exchange = try EditorExchange(hostBundleIdentifier:paths.bundleIdentifier,scenes:offers,renderer:nil)
        let launcher = suppliedLauncher ?? EditorLauncher(directory:paths.applicationSupport.appendingPathComponent("EditorExchange"))
        try await launcher.open(exchange:exchange,project:selectedMedia?.sceneProject,localizer:localizer)
    }
    @discardableResult
    func receiveEditorLink(_ url: URL) async throws -> Bool {
        guard case .importScene(let project) = try EditorLink(url:url) else { throw WallpaperError("此链接不是 Editor 工程导入请求。") }
        return await importSceneProject(project,addingToSelectedPlaylist:false)
    }
    func presentEditorFailure(_ error: Error) {
        let alert = NSAlert(); alert.messageText = localizer("无法打开 Editor")
        alert.informativeText = localizer.text(error.localizedDescription); alert.runModal()
    }
}
