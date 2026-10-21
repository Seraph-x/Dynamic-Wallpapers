import AppKit
import Combine
import WallpaperCore

@MainActor
struct AppCompositionOverrides {
    let paths: ApplicationPaths?
    let store: LibraryStore?
    let transcoding: TranscodeModel?
    let inspectorMedia: InspectorMediaModel?
    let managedImport: ManagedMediaImport?
    let thumbnails: ThumbnailLifetime?
    let presentation: (any ApplicationPresenting)?
    let loginItems: LoginItemController?
    let webInteractionPermissions: (any WebInteractionPermissionServicing)?
    let screenSaver: ScreenSaverModel?
    let fullScreenMonitor: OtherAppFullScreenMonitor?

    init(paths: ApplicationPaths? = nil, store: LibraryStore? = nil, transcoding: TranscodeModel? = nil,
         inspectorMedia: InspectorMediaModel? = nil, managedImport: ManagedMediaImport? = nil,
         thumbnails: ThumbnailLifetime? = nil, presentation: (any ApplicationPresenting)? = nil,
         loginItems: LoginItemController? = nil,
         webInteractionPermissions: (any WebInteractionPermissionServicing)? = nil,
         screenSaver: ScreenSaverModel? = nil,
         fullScreenMonitor: OtherAppFullScreenMonitor? = nil) {
        self.paths = paths
        self.store = store
        self.transcoding = transcoding
        self.inspectorMedia = inspectorMedia
        self.managedImport = managedImport
        self.thumbnails = thumbnails
        self.presentation = presentation
        self.loginItems = loginItems
        self.webInteractionPermissions = webInteractionPermissions
        self.screenSaver = screenSaver
        self.fullScreenMonitor = fullScreenMonitor
    }
}

@MainActor
struct AppEnvironment {
    let paths: ApplicationPaths
    let store: LibraryStore
    let transcoding: TranscodeModel
    let inspectorMedia: InspectorMediaModel
    let managedImport: ManagedMediaImport
    let managedFiles: ManagedMediaStore
    let mediaRemoval: ManagedMediaRemoval
    let thumbnails: ThumbnailLifetime
    let presentation: any ApplicationPresenting
    let loginItems: LoginItemController
    let webInteractionPermissions: any WebInteractionPermissionServicing
    let webRuntime: CEFApplicationRuntime
    let mirrorFrameRate: CurrentValueSubject<WallpaperMirrorFrameRate, Never>
    let desktop: DesktopCoordinator
    let webInteractionController: WebInteractionController
    let fullScreenMonitor: OtherAppFullScreenMonitor
    let lifecycle: ApplicationLifecycleController
    let previewLifetime: PreviewLifetime
    let systemWallpaperSync: SystemWallpaperSync
    let screenSaver: ScreenSaverModel?
    let screenSaverConstructionFailure: Error?
}

@MainActor
enum AppCompositionRoot {
    static func make(
        overrides: AppCompositionOverrides,
        setSystemDesktopImage: @escaping @MainActor (URL, String) throws -> Void
    ) -> AppEnvironment {
        let paths = overrides.paths ?? ApplicationPaths.production(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        let presentation = overrides.presentation ?? SystemApplicationPresentation()
        let loginItems = overrides.loginItems ?? LoginItemController(service: SystemLoginItemService())
        let webRuntime = CEFApplicationRuntime(cache: paths.cefCache)
        let surfaceFactory = SurfaceFactory(webPages: webRuntime)
        let thumbnails = overrides.thumbnails ?? ThumbnailLifetime(load: { item in
            try await MediaThumbnail.load(item, webPages: webRuntime)
        })
        let inspectorMedia = overrides.inspectorMedia ?? InspectorMediaModel(inspect: { item in
            try await MediaCompatibility.inspect(item, thumbnail: { item in
                try await thumbnails.load(item)
            }, validateTranscode: { url in
                let tools = try TranscodeTools.resolve(diagnosticsDirectory: paths.transcodeDiagnostics,
                    temporaryDirectory: paths.transcodeTemporary)
                try await TranscodeCompatibilityProbe.validate(url, tools: tools)
            })
        })
        let mirrorFrameRate = CurrentValueSubject<WallpaperMirrorFrameRate, Never>(.hz30)
        let desktop = DesktopCoordinator(surfaceFactory: surfaceFactory,
            mirrorFrameRate: { mirrorFrameRate.value })
        let permissions = overrides.webInteractionPermissions ?? SystemWebInteractionPermissionService()
        let webInteractionController = WebInteractionController(permissionService: permissions,
            setRuntimeEnabled: desktop.setWebInteractionEnabled,
            refreshRuntimeStatus: desktop.refreshWebInteractionStatus)
        let fullScreenMonitor = overrides.fullScreenMonitor ?? OtherAppFullScreenMonitor()
        let lifecycle = ApplicationLifecycleController(fullScreenMonitor: fullScreenMonitor)
        let previewLifetime = PreviewLifetime(surfaceFactory: surfaceFactory, desktopPreviews: desktop.previews)
        let transcoding = overrides.transcoding ?? TranscodeModel(tools: {
            try TranscodeTools.resolve(diagnosticsDirectory: paths.transcodeDiagnostics,
                temporaryDirectory: paths.transcodeTemporary)
        })
        let store = overrides.store ?? LibraryStore(
            url: paths.library, legacyURL: paths.legacyLibrary)
        let screenSaver: ScreenSaverModel?
        let screenSaverConstructionFailure: Error?
        if let supplied = overrides.screenSaver {
            screenSaver = supplied
            screenSaverConstructionFailure = nil
        } else {
            do {
                let directory = overrides.paths?.applicationSupport ?? store.url.deletingLastPathComponent()
                screenSaver = try ScreenSaverModel.makeDefault(directory: directory)
                screenSaverConstructionFailure = nil
            } catch {
                screenSaver = nil
                screenSaverConstructionFailure = error
            }
        }
        let managedImport = overrides.managedImport ?? ManagedMediaImport(
            files: ManagedMediaStore(directory: overrides.paths?.media ?? store.url.deletingLastPathComponent()
                .appendingPathComponent("Media")))
        let managedFiles = managedImport.files
        let mediaRemoval = ManagedMediaRemoval(files: managedFiles)
        let wallpaperSource = desktop.systemWallpaperSource
        let systemWallpaperSync = SystemWallpaperSync(
            store: SystemWallpaperStore(directory: overrides.paths?.systemWallpapers ??
                store.url.deletingLastPathComponent().appendingPathComponent("SystemWallpapers")),
            capture: wallpaperSource.capture, isCurrent: wallpaperSource.isCurrent,
            apply: setSystemDesktopImage)
        return AppEnvironment(paths: paths, store: store, transcoding: transcoding, inspectorMedia: inspectorMedia,
            managedImport: managedImport, managedFiles: managedFiles, mediaRemoval: mediaRemoval,
            thumbnails: thumbnails, presentation: presentation, loginItems: loginItems,
            webInteractionPermissions: permissions, webRuntime: webRuntime,
            mirrorFrameRate: mirrorFrameRate, desktop: desktop,
            webInteractionController: webInteractionController, fullScreenMonitor: fullScreenMonitor,
            lifecycle: lifecycle, previewLifetime: previewLifetime,
            systemWallpaperSync: systemWallpaperSync, screenSaver: screenSaver,
            screenSaverConstructionFailure: screenSaverConstructionFailure)
    }
}
