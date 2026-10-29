import XCTest
import WallpaperCore
import WallpaperMediaIntegration
@testable import WallpaperApp

@MainActor
final class SystemMediaAppSettingsTests: XCTestCase {
    func testMainDefaultsToDisabledAndSelectingSourcePersistsWithoutConsentOrReads() async throws {
        try await withFixture { fixture in
            XCTAssertEqual(fixture.controller.source, .disabled)
            XCTAssertTrue(fixture.model.mutate { $0.settings.systemMediaSource = .music })
            XCTAssertEqual(fixture.controller.source, .music)
            XCTAssertEqual(try fixture.store.load().settings.systemMediaSource, .music)
            let reads = await fixture.service.reads; XCTAssertTrue(reads.isEmpty)
            XCTAssertEqual(fixture.controller.status, .waitingForPlayback)
        }
    }

    func testMainRestoresPersistedSelectionAndReopensWithTheSavedSource() async throws {
        try await withFixture(source: .spotify) { fixture in
            XCTAssertEqual(fixture.controller.source, .spotify)
            XCTAssertTrue(fixture.model.mutate { $0.settings.systemMediaSource = .music })
            try await fixture.model.shutdownAndWait()
            let controller = SystemMediaController(service: fixture.service, pollInterval: 3600)
            let reopened = AppModel(paths: fixture.paths, store: fixture.store, systemMedia: controller,
                setSystemDesktopImage: { _, _ in throw WallpaperError("Media settings must not change a personal wallpaper") })
            XCTAssertEqual(controller.source, .music)
            let reads = await fixture.service.reads; XCTAssertTrue(reads.isEmpty)
            try await reopened.shutdownAndWait()
        }
    }

    func testLibraryLoadFailureForcesInjectedSelectionOff() async throws {
        try await withFixture(source: .music, corrupt: true) { fixture in
            XCTAssertTrue(fixture.model.loadFailed)
            XCTAssertEqual(fixture.controller.source, .disabled)
            XCTAssertEqual(fixture.controller.status, .disabled)
            let reads = await fixture.service.reads; XCTAssertTrue(reads.isEmpty)
        }
    }

    private struct Fixture {
        let paths: ApplicationPaths
        let store: LibraryStore
        let service: SceneMediaProviderFixture
        let controller: SystemMediaController
        let model: AppModel
    }

    private func withFixture(source: SystemMediaSource = .disabled, corrupt: Bool = false,
                             _ body: (Fixture) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for folder in ["Home", "Temp"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let paths = try ApplicationPaths.resolve(arguments: ["--validation-data-root", directory.path],
            bundleIdentifier: "local.dynamicwallpaper.app.validation.media", configuredBundleIdentifier: "local.dynamicwallpaper.app",
            environment: ["CFFIXED_USER_HOME": directory.appendingPathComponent("Home").path,
                          "TMPDIR": directory.appendingPathComponent("Temp").path])
        let store = LibraryStore(url: paths.library)
        var library = Library.empty; library.settings.systemMediaSource = source
        try store.save(library)
        if corrupt { try Data("invalid owned library".utf8).write(to: paths.library) }
        let service = SceneMediaProviderFixture(), controller = SystemMediaController(service: service, pollInterval: 3600)
        controller.configure(source: source)
        let model = AppModel(paths: paths, store: store, systemMedia: controller,
            setSystemDesktopImage: { _, _ in throw WallpaperError("Media settings must not change a personal wallpaper") })
        let fixture = Fixture(paths: paths, store: store, service: service, controller: controller, model: model)
        var failures: [Error] = []
        do { try await body(fixture) } catch { failures.append(error) }
        do { try await model.shutdownAndWait() } catch { failures.append(error) }
        do { try FileManager.default.removeItem(at: directory) } catch { failures.append(error) }
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
    }
}
