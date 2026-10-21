import SwiftUI

// SceneBuilder cannot branch on availability. Select the app at the entry point
// so macOS 14 keeps its supported scene types and the same shared UI.
@available(macOS 27.0, *)
struct MacOS27WallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    private let product: ProductBundleMetadata

    init() {
        let startup = DynamicWallpaperMain.requireStartup()
        product = startup.product
        let model = AppModel(paths: startup.paths)
        do { try model.paths.appendEvidence(event: "startup") }
        catch { fatalError("Validation startup evidence failed: \(error)") }
        _model = StateObject(wrappedValue: model)
        delegate.model = model
    }

    var body: some Scene {
        let scenes = WallpaperScenes(model: model, product: product)
        // AppModel and explicit menu actions own management-window presentation.
        // Automatic restoration on macOS 27 otherwise opens UI at login.
        scenes.library.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
        scenes.menuBar
        scenes.transcode.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
        scenes.settings.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
    }
}
