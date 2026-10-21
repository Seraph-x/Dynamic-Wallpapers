import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class BatchAppModelTests: XCTestCase {
    private func withModel(_ body: (AppModel, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail(error.localizedDescription) } }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        var library = Library.empty
        library.media = [MediaItem(url: directory.appendingPathComponent("original.png"), kind: .image, width: 8, height: 8)]
        library.playlists[0].entries = [PlaylistEntry(mediaID: library.media[0].id)]
        try store.save(library)
        try Data("original file".utf8).write(to: library.media[0].url)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        try body(model, directory)
    }

    func testBatchFavoritePersistsAndClearsHiddenSelection() throws {
        try withModel { model, _ in
            let ids = Set(model.library.media.map(\.id))
            XCTAssertTrue(model.performBatch(.favoriteMedia(ids: ids, value: true)))
            model.section = .favorites
            model.batchSelection.start(); model.batchSelection.selectAll(model.visibleBatchIDs)
            XCTAssertTrue(model.performBatch(.favoriteMedia(ids: ids, value: false)))
            XCTAssertTrue(model.batchSelection.ids.isEmpty)
            XCTAssertTrue(model.filteredMedia.isEmpty)
            XCTAssertEqual(try model.store.load(), model.library)
        }
    }

    func testBatchRemovalDoesNotDeleteOriginalFile() throws {
        try withModel { model, _ in
            let item = model.library.media[0]
            XCTAssertTrue(model.performBatch(.removeMedia(ids: [item.id])))
            XCTAssertTrue(model.library.media.isEmpty)
            XCTAssertTrue(model.library.playlists[0].entries.isEmpty)
            XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "original file")
        }
    }

    func testInvalidSelectionPreservesMemoryDiskAndSelection() throws {
        try withModel { model, _ in
            let original = model.library, data = try Data(contentsOf: model.store.url)
            model.batchSelection.start(); model.batchSelection.selectAll(model.visibleBatchIDs)
            let selection = model.batchSelection
            XCTAssertFalse(model.performBatch(.removeMedia(ids: [model.library.media[0].id, UUID()])))
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.library, original)
            XCTAssertEqual(try Data(contentsOf: model.store.url), data)
            XCTAssertEqual(model.batchSelection, selection)
        }
    }

    func testActualSaveFailurePreservesMemoryAndSelection() throws {
        try withModel { model, _ in
            let original = model.library, data = try Data(contentsOf: model.store.url)
            model.batchSelection.start(); model.batchSelection.selectAll(model.visibleBatchIDs)
            let selection = model.batchSelection
            // Make the existing file immutable; restore flags before temporary-directory cleanup.
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: model.store.url.path)
            defer { do { try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: model.store.url.path) } catch { XCTFail(error.localizedDescription) } }
            XCTAssertFalse(model.performBatch(.favoriteMedia(ids: selection.ids, value: true)))
            XCTAssertEqual(model.library, original)
            XCTAssertEqual(try Data(contentsOf: model.store.url), data)
            XCTAssertEqual(model.batchSelection, selection)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.setGlobalMute(false))
            XCTAssertTrue(model.library.settings.isMuted)
            XCTAssertEqual(try Data(contentsOf: model.store.url), data)
        }
    }

    func testSearchAndSectionResetSelection() throws {
        try withModel { model, _ in
            model.batchSelection.start(); model.batchSelection.selectAll(model.visibleBatchIDs)
            model.search = "missing"
            XCTAssertTrue(model.batchSelection.ids.isEmpty)
            XCTAssertTrue(model.batchSelection.isActive)
            XCTAssertTrue(model.visibleBatchIDs.isEmpty)
            model.section = .playlist(model.library.playlists[0].id)
            XCTAssertFalse(model.batchSelection.isActive)
            model.batchSelection.start(); model.batchSelection.selectAll(model.visibleBatchIDs)
            XCTAssertEqual(model.batchSelection.ids, Set(model.library.playlists[0].entries.map(\.id)))
            model.section = .library
            XCTAssertTrue(model.batchSelection.ids.isEmpty)
        }
    }

    func testGlobalMutePersistsWithoutChangingEntryAudio() throws {
        try withModel { model, _ in
            let entries = model.library.playlists[0].entries
            XCTAssertTrue(model.setGlobalMute(false))
            XCTAssertFalse(try model.store.load().settings.isMuted)
            XCTAssertEqual(model.library.playlists[0].entries, entries)
            XCTAssertTrue(model.setGlobalMute(true))
            XCTAssertTrue(try model.store.load().settings.isMuted)
        }
    }

    func testBrokenLibraryRejectsBatchAndMute() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail(error.localizedDescription) } }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let broken = Data("not json".utf8)
        try broken.write(to: store.url)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        XCTAssertFalse(model.performBatch(.removeMedia(ids: [UUID()])))
        XCTAssertFalse(model.setGlobalMute(false))
        XCTAssertEqual(try Data(contentsOf: store.url), broken)
        XCTAssertTrue(model.library.settings.isMuted)
    }
}
