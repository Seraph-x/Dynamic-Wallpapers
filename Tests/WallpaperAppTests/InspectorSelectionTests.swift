import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class InspectorSelectionTests: XCTestCase {
    func testChangingSectionClearsOldMediaAndEntrySelection() async throws {
        try await withModel { model in
            let original = model.library
            model.selectedMediaID = original.media[0].id
            model.section = .playlist(original.playlists[0].id)
            XCTAssertNil(model.selectedMediaID, "A library selection must not masquerade as a playlist entry")
            XCTAssertNil(model.selectedMedia)
            model.selectedEntryID = original.playlists[0].entries[0].id
            model.section = .playlist(original.playlists[1].id)
            XCTAssertNil(model.selectedEntryID)
            XCTAssertNil(model.selectedMedia)
            XCTAssertEqual(model.library, original)
            XCTAssertEqual(try model.store.load(), original)
        }
    }

    func testSelectingEntrySynchronizesMediaWithoutAViewCallback() async throws {
        try await withModel { model in
            let playlist = model.library.playlists[0]
            model.section = .playlist(playlist.id)
            model.selectedEntryID = playlist.entries[0].id
            XCTAssertEqual(model.selectedMediaID, playlist.entries[0].mediaID)
            XCTAssertEqual(model.selectedMedia?.id, playlist.entries[0].mediaID)
            XCTAssertEqual(model.selectedEntryAudio, playlist.entries[0].audio)
        }
    }

    func testClearingEntryCannotLeaveStaleDetails() async throws {
        try await withModel { model in
            let playlist = model.library.playlists[0]
            model.section = .playlist(playlist.id)
            model.selectedEntryID = playlist.entries[0].id
            model.selectedMediaID = playlist.entries[0].mediaID
            model.selectedEntryID = nil
            XCTAssertNil(model.selectedMedia)
            XCTAssertEqual(model.selectedEntryAudio, AudioSettings())
        }
    }

    func testMismatchedEntryAndMediaCannotProducePartialDetails() async throws {
        try await withModel { model in
            let playlist = model.library.playlists[0]
            model.section = .playlist(playlist.id)
            model.selectedEntryID = playlist.entries[0].id
            model.selectedMediaID = model.library.media[1].id
            XCTAssertNil(model.selectedMedia, "Never show another item's timing or audio beneath this media")
            XCTAssertEqual(model.selectedEntryAudio, AudioSettings())
        }
    }

    func testRepeatedMediaEntriesKeepIndependentAudio() async throws {
        try await withModel { model in
            let playlist = model.library.playlists[0]
            model.section = .playlist(playlist.id)
            for entry in playlist.entries {
                model.selectedEntryID = entry.id
                XCTAssertEqual(model.selectedMedia?.id, entry.mediaID)
                XCTAssertEqual(model.selectedEntryAudio, entry.audio)
            }
            XCTAssertNotEqual(playlist.entries[0].audio, playlist.entries[1].audio)
            XCTAssertEqual(try model.store.load(), model.library)
        }
    }

    func testRemovingSelectedEntryClearsItsDetailsNotTheMedia() async throws {
        try await withModel { model in
            var playlist = model.library.playlists[0]
            let entry = playlist.entries[0]
            model.section = .playlist(playlist.id)
            model.selectedEntryID = entry.id
            model.selectedMediaID = entry.mediaID
            playlist.entries.removeAll { $0.id == entry.id }
            model.updatePlaylist(playlist)
            XCTAssertNil(model.selectedEntryID)
            XCTAssertNil(model.selectedMedia)
            XCTAssertTrue(model.library.media.contains { $0.id == entry.mediaID })
        }
    }

    func testFavoritesOnlyResolveVisibleFavoritesAndDisplaysHaveNoMediaSelection() async throws {
        try await withModel { model in
            let item = model.library.media[0]
            model.section = .favorites
            model.selectedMediaID = item.id
            XCTAssertNil(model.selectedMedia)
            model.favorite(item.id)
            model.selectedMediaID = item.id
            XCTAssertEqual(model.selectedMedia?.id, item.id)
            model.section = .displays
            XCTAssertNil(model.selectedMedia)
        }
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inspector-selection-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Selection fixture cleanup failed: \(error)") }
        }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        var library = Library.empty
        library.media = ["first", "second"].map {
            MediaItem(url: directory.appendingPathComponent("\($0).mp4"), kind: .video, width: 64, height: 64)
        }
        library.playlists = [
            Playlist(name: "Wlop", entries: [
                PlaylistEntry(mediaID: library.media[0].id, audio: AudioSettings(volume: 0.2)),
                PlaylistEntry(mediaID: library.media[0].id, audio: AudioSettings(isMuted: true, volume: 0.8))
            ]),
            Playlist(name: "Other", entries: [PlaylistEntry(mediaID: library.media[1].id)])
        ]
        try store.save(library)
        let model = AppModel(store: store)
        do { try await body(model) }
        catch { try await model.shutdownAndWait(); throw error }
        try await model.shutdownAndWait()
    }
}
