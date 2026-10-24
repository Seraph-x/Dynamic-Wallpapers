import AppKit
import WallpaperCore

enum EditorInstallChoice { case download, cancel }

@MainActor protocol EditorLaunchServicing {
    func installedEditor() -> URL?
    func installChoice(localizer: AppLocalizer) -> EditorInstallChoice
    func downloadEditor() throws
    func validateEditor(_ app: URL) throws
    func open(_ url: URL, with app: URL) async throws
}

@MainActor final class EditorLauncher {
    private let services: any EditorLaunchServicing
    private let publisher: EditorExchangePublisher
    init(directory: URL, services: (any EditorLaunchServicing)? = nil) {
        self.services = services ?? MacEditorLaunchServices(); publisher = EditorExchangePublisher(directory:directory)
    }
    func open(exchange: EditorExchange, project: SceneProjectReference?, localizer: AppLocalizer) async throws {
        guard let application = services.installedEditor() else {
            switch services.installChoice(localizer:localizer) {
            case .cancel: return
            case .download: try services.downloadEditor(); return
            }
        }
        try services.validateEditor(application)
        let descriptor = try await publisher.publish(exchange)
        try await services.open(EditorLink.openEditor(project:project,descriptor:descriptor).url(),with:application)
    }
}

@MainActor final class MacEditorLaunchServices: EditorLaunchServicing {
    static let identifier = "local.dynamicwallpaper.editor"
    func installedEditor() -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier:Self.identifier) }
    func installChoice(localizer: AppLocalizer) -> EditorInstallChoice {
        let alert = EditorInstallPrompt.makeAlert(localizer:localizer)
        NSApplication.shared.activate(ignoringOtherApps:true)
        switch alert.runModal() { case .alertFirstButtonReturn: return .download; default: return .cancel }
    }
    func downloadEditor() throws {
        guard NSWorkspace.shared.open(URL(string:"https://github.com/Seraph-x/Dynamic-Wallpapers/releases?q=editor&expanded=true")!) else { throw WallpaperError("无法打开 Editor 下载页面。") }
    }
    func validateEditor(_ app: URL) throws {
        guard app.isFileURL, app.pathExtension.lowercased() == "app", let bundle = Bundle(url:app),
              bundle.bundleIdentifier == Self.identifier, bundle.object(forInfoDictionaryKey:"DWEditorExchangeAPI") as? String == "1" else { throw WallpaperError("所选应用不是兼容的 Editor。") }
    }
    func open(_ url: URL, with app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        _ = try await NSWorkspace.shared.open([url],withApplicationAt:app,configuration:configuration)
    }
}
