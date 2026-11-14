import AppKit
import WallpaperCore

extension AppModel {
    @discardableResult
    func receiveEditorLink(_ url: URL) async throws -> Bool {
        guard case .importScene(let project) = try EditorLink(url:url) else { throw WallpaperError("此链接不是 Editor 工程导入请求。") }
        return await importSceneProject(project,addingToSelectedPlaylist:false)
    }
    func presentSceneImportFailure(_ error: Error) {
        let alert = NSAlert(); alert.messageText = localizer("无法导入场景")
        alert.informativeText = localizer.text(error.localizedDescription); alert.runModal()
    }
}
