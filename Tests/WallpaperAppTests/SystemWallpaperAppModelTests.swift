import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SystemWallpaperAppModelTests: XCTestCase {
    func testTogglePersistsAndRestoresWithoutChangingOtherSettings() async throws {
        let fixture = try SystemWallpaperAppFixture()
        addTeardownBlock { @MainActor in try await fixture.close() }
        let model = fixture.model
        XCTAssertFalse(model.systemWallpaperSync.enabled)
        var expected = model.library
        expected.settings.systemWallpaperSyncEnabled = true
        XCTAssertTrue(model.setSystemWallpaperSyncEnabled(true))
        XCTAssertEqual(model.library, expected)
        XCTAssertEqual(try fixture.store.load(), expected)
        XCTAssertTrue(model.systemWallpaperSync.enabled)
        XCTAssertNil(model.systemWallpaperFailure)
        XCTAssertTrue(fixture.setter.attempts.isEmpty, "No committed wallpaper exists yet")
        try await model.shutdownAndWait()
        let restored = AppModel(store: fixture.store, setSystemDesktopImage: fixture.setter.apply)
        addTeardownBlock { @MainActor in try await restored.shutdownAndWait() }
        XCTAssertTrue(restored.systemWallpaperSync.enabled)
        XCTAssertTrue(restored.setSystemWallpaperSyncEnabled(false))
        XCTAssertFalse(try fixture.store.load().settings.systemWallpaperSyncEnabled)
        XCTAssertTrue(fixture.setter.attempts.isEmpty)
    }

    func testSaveFailureCannotEnableOrDisableTheLiveSetting() async throws {
        for enabled in [false, true] {
            let fixture = try SystemWallpaperAppFixture(enabled: enabled)
            addTeardownBlock { @MainActor in try await fixture.close() }
            let original = fixture.model.library
            let backup = fixture.store.url.appendingPathExtension("backup")
            try FileManager.default.moveItem(at: fixture.store.url, to: backup)
            try FileManager.default.createDirectory(at: fixture.store.url, withIntermediateDirectories: false)
            XCTAssertFalse(fixture.model.setSystemWallpaperSyncEnabled(!enabled))
            XCTAssertEqual(fixture.model.library, original)
            XCTAssertEqual(fixture.model.systemWallpaperSync.enabled, enabled)
            XCTAssertNotNil(fixture.model.systemWallpaperFailure?.diagnostics)
            XCTAssertNil(fixture.model.failure, "Setting errors must stay in the setting's error presentation")
            XCTAssertTrue(fixture.setter.attempts.isEmpty)
            try FileManager.default.removeItem(at: fixture.store.url)
            try FileManager.default.moveItem(at: backup, to: fixture.store.url)
            XCTAssertEqual(try fixture.store.load(), original)
            XCTAssertTrue(fixture.model.setSystemWallpaperSyncEnabled(!enabled))
            XCTAssertNil(fixture.model.systemWallpaperFailure)
        }
    }

    func testUnreadableLibraryAndShutdownRejectSettingChanges() async throws {
        let fixture = try SystemWallpaperAppFixture(enabled: true)
        addTeardownBlock { @MainActor in try await fixture.close() }
        try await fixture.model.shutdownAndWait()
        XCTAssertFalse(fixture.model.systemWallpaperSync.enabled)
        XCTAssertTrue(try fixture.store.load().settings.systemWallpaperSyncEnabled)
        XCTAssertFalse(fixture.model.setSystemWallpaperSyncEnabled(false))
        XCTAssertNotNil(fixture.model.systemWallpaperFailure)
        let corrupt = Data("not a library".utf8)
        try corrupt.write(to: fixture.store.url)
        let unreadable = AppModel(store: fixture.store, setSystemDesktopImage: fixture.setter.apply)
        addTeardownBlock { @MainActor in try await unreadable.shutdownAndWait() }
        XCTAssertTrue(unreadable.loadFailed)
        XCTAssertFalse(unreadable.setSystemWallpaperSyncEnabled(true))
        XCTAssertFalse(unreadable.systemWallpaperSync.enabled)
        XCTAssertNotNil(unreadable.systemWallpaperFailure)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url), corrupt)
    }

    func testClearMediaLibraryPreservesSynchronizationSettingAndExportedPoster() async throws {
        let fixture = try SystemWallpaperAppFixture(enabled: true, bound: true)
        addTeardownBlock { @MainActor in try await fixture.close() }
        let url = try await fixture.syncedImage()
        let data = try Data(contentsOf: url)
        XCTAssertTrue(fixture.model.clearMediaLibrary())
        await fixture.model.systemWallpaperSync.waitForPendingOperations()
        XCTAssertTrue(fixture.model.systemWallpaperSync.enabled)
        XCTAssertTrue(try fixture.store.load().settings.systemWallpaperSyncEnabled)
        XCTAssertTrue(fixture.model.library.media.isEmpty)
        XCTAssertTrue(fixture.model.library.displays.isEmpty)
        XCTAssertTrue(fixture.model.systemWallpaperSync.states.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(fixture.setter.attempts.count, 1)
    }

    func testResetRejectsHealthyLibraryWithoutChangingSynchronization() async throws {
        let fixture = try SystemWallpaperAppFixture(enabled: true, bound: true)
        addTeardownBlock { @MainActor in try await fixture.close() }
        let url = try await fixture.syncedImage()
        let original = fixture.model.library
        fixture.model.resetLibrary()
        XCTAssertNotNil(fixture.model.failure)
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertEqual(try fixture.store.load(), original)
        XCTAssertTrue(fixture.model.systemWallpaperSync.enabled)
        XCTAssertEqual(fixture.model.systemWallpaperSync.states[fixture.screenID], .synced(url))
    }

    func testDisconnectedSystemServiceFailsBeforeCallingMacOS() {
        XCTAssertThrowsError(try SystemDesktopImageService().setImage(
            at: URL(fileURLWithPath: "/unused-poster.png"), displayID: "missing-system-wallpaper-test-display")) {
            XCTAssertTrue($0.localizedDescription.contains("目标显示器已断开"))
        }
    }
}
