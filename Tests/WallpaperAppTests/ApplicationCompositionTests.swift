import Combine
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ApplicationCompositionTests: XCTestCase {
    func testSuppliedServicesRemainTheEnvironmentServices() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let transcoding = TranscodeModel()
        let inspector = InspectorMediaModel(inspect: { _ in throw CancellationError() })
        let files = ManagedMediaStore(directory: directory.appendingPathComponent("Managed"))
        let managedImport = ManagedMediaImport(files: files)
        let thumbnails = ThumbnailLifetime(load: { _ in nil })
        let presentation = TestApplicationPresentation()
        let loginItems = LoginItemController(service: TestLoginItemService())
        let permissions = TestWebInteractionPermissionService()
        let screenSaver = try ScreenSaverModel.makeDefault(directory: directory)
        let fullScreen = OtherAppFullScreenMonitor(sample: { false })

        let environment = AppCompositionRoot.make(overrides: AppCompositionOverrides(
            store: store, transcoding: transcoding, inspectorMedia: inspector,
            managedImport: managedImport, thumbnails: thumbnails, presentation: presentation,
            loginItems: loginItems, webInteractionPermissions: permissions,
            screenSaver: screenSaver, fullScreenMonitor: fullScreen),
            setSystemDesktopImage: { _, _ in })

        XCTAssertEqual(environment.store.url, store.url)
        XCTAssertTrue(environment.transcoding === transcoding)
        XCTAssertTrue(environment.inspectorMedia === inspector)
        XCTAssertTrue(environment.managedImport === managedImport)
        XCTAssertTrue(environment.managedFiles === files)
        XCTAssertTrue(environment.thumbnails === thumbnails)
        XCTAssertTrue(environment.presentation as AnyObject === presentation)
        XCTAssertTrue(environment.loginItems === loginItems)
        XCTAssertTrue(environment.webInteractionPermissions as AnyObject === permissions)
        XCTAssertTrue(environment.screenSaver === screenSaver)
        XCTAssertTrue(environment.fullScreenMonitor === fullScreen)
        XCTAssertNil(environment.screenSaverConstructionFailure)
        shutdownSignals(environment)
    }

    func testDefaultEnvironmentOwnsOneIdleRuntimeWithoutStartingMedia() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))

        let environment = AppCompositionRoot.make(
            overrides: AppCompositionOverrides(store: store),
            setSystemDesktopImage: { _, _ in })

        XCTAssertEqual(environment.webRuntime.activePageCount, 0)
        XCTAssertTrue(environment.desktop.windowIdentities.isEmpty)
        XCTAssertEqual(environment.previewLifetime.activeSurfaceCount, 0)
        XCTAssertFalse(environment.transcoding.hasActiveWork)
        shutdownSignals(environment)
        try await environment.webRuntime.shutdown()
    }

    func testDefaultScreenSaverConstructionFailureIsReturnedAsData() {
        let remoteStore = LibraryStore(url: URL(string: "https://example.invalid/library.json")!)

        let environment = AppCompositionRoot.make(
            overrides: AppCompositionOverrides(store: remoteStore),
            setSystemDesktopImage: { _, _ in })

        XCTAssertNil(environment.screenSaver)
        XCTAssertNotNil(environment.screenSaverConstructionFailure)
        shutdownSignals(environment)
    }

    func testInjectedValidationPathsOwnDefaultStores() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("Home")
        let temporary = root.appendingPathComponent("Temp")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try ApplicationPaths.resolve(arguments: ["--validation-data-root", root.path],
            bundleIdentifier: "local.dynamicwallpaper.app.validation.test",
            configuredBundleIdentifier: "local.dynamicwallpaper.app",
            environment: ["CFFIXED_USER_HOME": home.path, "TMPDIR": temporary.path])
        let environment = AppCompositionRoot.make(overrides: AppCompositionOverrides(paths: paths),
            setSystemDesktopImage: { _, _ in })
        XCTAssertEqual(environment.store.url, paths.library)
        XCTAssertEqual(environment.managedFiles.directory, paths.media)
        XCTAssertEqual(environment.paths.cefCache, paths.cefCache)
        shutdownSignals(environment)
    }

    private func shutdownSignals(_ environment: AppEnvironment) {
        environment.webInteractionController.shutdown()
        _ = environment.lifecycle.beginShutdown(plan: ApplicationShutdownPlan(
            immediate: {}, importing: nil, drain: {}, makeCloseTasks: { [] },
            requireReleased: {}, shutdownWebRuntime: {}))
    }
}
