import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ManagedMediaRemovalTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model = AppModel(store: LibraryStore(url: directory.appendingPathComponent("library.json")))
    }

    override func tearDown() async throws {
        try await model.shutdownAndWait()
        try FileManager.default.removeItem(at: directory)
    }

    func testSingleAndBatchRemovalDeleteOnlyOwnedCopies() async throws {
        let first = try await importImage("first.png")
        let second = try await importImage("second.png")
        let third = try await importImage("third.png")
        let list = model.library.playlists[0].id
        for item in [first, second, third] { model.add(item.id, to: list) }
        model.removeMedia(first.id)
        XCTAssertTrue(model.performBatch(.removeMedia(ids: [second.id, third.id])))
        await model.waitForMediaRemovals()
        XCTAssertTrue(model.library.media.isEmpty)
        XCTAssertTrue(model.library.playlists[0].entries.isEmpty)
        XCTAssertTrue(model.library.pendingMediaDeletions.isEmpty)
        for item in [first, second, third] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.origin).url.path))
        }
        XCTAssertEqual(try model.store.load(), model.library)
    }

    func testRemovingPlaylistEntryKeepsManagedFile() async throws {
        let item = try await importImage("source.png")
        let list = model.library.playlists[0].id
        model.add(item.id, to: list)
        let entry = model.library.playlists[0].entries[0].id
        XCTAssertTrue(model.performBatch(.removeEntries(playlistID: list, ids: [entry])))
        await model.waitForMediaRemovals()
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(model.library.media, [item])
    }

    func testFailedSaveDoesNotDeleteFilesOrQueueCleanup() async throws {
        let item = try await importImage("source.png")
        let original = model.library
        model.selectedMediaID = item.id
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: model.store.url.path)
        defer { do { try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: model.store.url.path) } catch { XCTFail("\(error)") } }
        model.removeMedia(item.id)
        await model.waitForMediaRemovals()
        XCTAssertNotNil(model.failure)
        XCTAssertEqual(model.library, original)
        XCTAssertEqual(model.selectedMediaID, item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }

    func testCleanupFailureRemainsVisibleAndRetriesAfterRestart() async throws {
        let item = try await importImage("source.png")
        let folder = item.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: folder.path)
        model.removeMedia(item.id)
        await model.waitForMediaRemovals()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.path)
        XCTAssertNotNil(model.failure)
        XCTAssertEqual(model.library.pendingMediaDeletions, [item])
        XCTAssertEqual(try model.store.load().pendingMediaDeletions, [item])
        let store = model.store
        try await model.shutdownAndWait()
        model = AppModel(store: store)
        await model.waitForMediaRemovals()
        XCTAssertTrue(model.library.pendingMediaDeletions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(model.failure)
    }

    func testClearBacksUpExactConfigurationAndPreservesSettingsAndOriginals() async throws {
        let item = try await importImage("source.png")
        model.favorite(item.id)
        XCTAssertTrue(model.mutate {
            $0.settings.isMuted = false
            $0.settings.pauseOnLowPower = true
            $0.settings.showDockIcon = false
            $0.displays = [DisplayBinding(id: "offline", source: .media(item.id, audio: AudioSettings()))]
        })
        let before = try Data(contentsOf: model.store.url)
        let settings = model.library.settings
        let poster = directory.appendingPathComponent("SystemWallpapers/keep.png")
        try FileManager.default.createDirectory(at: poster.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("system wallpaper".utf8).write(to: poster)
        XCTAssertTrue(model.clearMediaLibrary())
        await model.waitForMediaRemovals()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(model.lastLibraryBackup)), before)
        XCTAssertEqual(model.library.settings, settings)
        XCTAssertTrue(model.library.media.isEmpty)
        XCTAssertTrue(model.library.playlists.isEmpty)
        XCTAssertTrue(model.library.displays.isEmpty)
        XCTAssertTrue(model.library.pendingMediaDeletions.isEmpty)
        XCTAssertEqual(try model.store.load(), model.library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.origin).url.path))
        XCTAssertEqual(try Data(contentsOf: poster), Data("system wallpaper".utf8))
    }

    func testBackupFailureDoesNotClearLibrary() async throws {
        let item = try await importImage("source.png")
        let before = model.library
        try FileManager.default.removeItem(at: model.store.url)
        try FileManager.default.createDirectory(at: model.store.url, withIntermediateDirectories: false)
        XCTAssertFalse(model.clearMediaLibrary())
        await model.waitForMediaRemovals()
        XCTAssertEqual(model.library, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertNotNil(model.failure)
    }

    func testMissingConfigurationPreventsUnbackedClear() async throws {
        let item = try await importImage("source.png")
        let before = model.library
        try FileManager.default.removeItem(at: model.store.url)
        XCTAssertFalse(model.clearMediaLibrary())
        await model.waitForMediaRemovals()
        XCTAssertEqual(model.library, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertNotNil(model.failure)
    }

    func testLegacyRemovalDoesNotTouchOriginal() async throws {
        let source = try makeImage("legacy.png")
        let item = MediaItem(url: source, kind: .image, width: 2, height: 2)
        XCTAssertTrue(model.mutate { $0.media.append(item) })
        model.removeMedia(item.id)
        await model.waitForMediaRemovals()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(model.library.pendingMediaDeletions.isEmpty)
    }

    func testAcknowledgementSaveFailureRetainsQueueEvenAfterFileWasDeleted() async throws {
        let item = try await importImage("source.png")
        model.removeMedia(item.id)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: model.store.url.path)
        await model.waitForMediaRemovals()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: model.store.url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(model.library.pendingMediaDeletions, [item])
        XCTAssertNotNil(model.failure)
        let store = model.store
        try await model.shutdownAndWait()
        model = AppModel(store: store)
        await model.waitForMediaRemovals()
        XCTAssertNil(model.failure, model.failure?.localizedDescription ?? "")
        XCTAssertTrue(try store.load().pendingMediaDeletions.isEmpty)
    }

    private func importImage(_ name: String) async throws -> MediaItem {
        let source = try makeImage(name)
        model.importURLs([source])
        let deadline = ContinuousClock.now + .seconds(5)
        while model.importing {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Import timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.failure)
        return try XCTUnwrap(model.library.media.last)
    }

    private func makeImage(_ name: String) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let source = directory.appendingPathComponent(name)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        return source
    }
}
