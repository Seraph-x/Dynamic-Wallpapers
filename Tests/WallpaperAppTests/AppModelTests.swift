import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class AppModelTests: XCTestCase {
    func testCurrentPlaylistAudioChangesOnlyThePlayingEntryInThatPlaylist() throws {
        _ = NSApplication.shared
        let screenID = try XCTUnwrap(NSScreen.main?.wallpaperID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let item = MediaItem(url: directory.appendingPathComponent("shared.mov"),
                             kind: .video, width: 64, height: 64)
        let playing = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.25))
        let sibling = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.5))
        let otherListEntry = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.75))
        let direct = DisplayBinding(id: "offline-direct",
            source: .media(item.id, audio: AudioSettings(volume: 0.9)))
        var library = Library.empty
        library.media = [item]
        library.playlists = [Playlist(name: "Current", entries: [playing, sibling]),
                             Playlist(name: "Other", entries: [otherListEntry])]
        library.displays = [DisplayBinding(id: screenID, playlistID: library.playlists[0].id,
                                           currentEntryID: playing.id), direct]
        try store.save(library)
        let model = AppModel(store: store)
        defer { model.shutdown() }

        XCTAssertEqual(model.currentWallpaperAudioTargets.count, 1)
        let target = try XCTUnwrap(model.currentWallpaperAudioTargets.first)
        XCTAssertEqual(target.playlistName, "Current")
        XCTAssertEqual(target.mediaName, "shared")
        XCTAssertEqual(target.audio, playing.audio)
        XCTAssertTrue(model.updateCurrentWallpaperAudio(
            AudioSettings(isMuted: true, volume: 0.4), targetID: target.id))

        let saved = try store.load()
        XCTAssertEqual(saved.playlists[0].entries[0].audio, AudioSettings(isMuted: true, volume: 0.4))
        XCTAssertEqual(saved.playlists[0].entries[1].audio, sibling.audio)
        XCTAssertEqual(saved.playlists[1].entries[0].audio, otherListEntry.audio)
        XCTAssertEqual(saved.displays.first { $0.id == direct.id }, direct)
    }

    func testRenameMediaPersistsAndRejectsBlankNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let item = MediaItem(url: directory.appendingPathComponent("forest/index.html"), kind: .web,
                             width: 640, height: 360, backend: .web,
                             webProject: WebProjectReference(root: directory.appendingPathComponent("forest"),
                                                             entry: "index.html"))
        var library = Library.empty
        library.media = [item]
        try store.save(library)
        let model = AppModel(store: store)
        defer { model.shutdown() }

        XCTAssertTrue(model.renameMedia(item.id, name: "林间精灵"))
        XCTAssertEqual(model.library.media.first?.name, "林间精灵")
        XCTAssertEqual(try store.load().media.first?.customName, "林间精灵")
        XCTAssertFalse(model.renameMedia(item.id, name: "  \n"))
        XCTAssertEqual(model.library.media.first?.name, "林间精灵")
    }

    func testCurrentWallpaperAudioUpdatesDirectGroupAndExcludesNonAudioWallpaper() throws {
        _ = NSApplication.shared
        let screenID = try XCTUnwrap(NSScreen.main?.wallpaperID)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let video = MediaItem(url: directory.appendingPathComponent("direct.mov"),
                              kind: .video, width: 64, height: 64)
        let directGroup = UUID()
        var library = Library.empty
        library.media = [video]
        let directSource = DisplaySource.media(video.id, audio: AudioSettings(volume: 0.3))
        library.displays = [DisplayBinding(id: screenID, source: directSource, groupID: directGroup),
                            DisplayBinding(id: "offline", source: directSource, groupID: directGroup)]
        try store.save(library)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        XCTAssertEqual(model.currentWallpaperAudioTargets.count, 1)
        let directTarget = try XCTUnwrap(model.currentWallpaperAudioTargets.first)
        XCTAssertNil(directTarget.playlistName)
        XCTAssertTrue(model.updateCurrentWallpaperAudio(
            AudioSettings(isMuted: true, volume: 0.6), targetID: directTarget.id))
        let saved = try store.load()
        XCTAssertEqual(saved.displays.count, 2)
        for binding in saved.displays {
            guard case .media(let savedMediaID, let savedAudio) = binding.source else {
                return XCTFail("Direct wallpaper source changed kind")
            }
            XCTAssertEqual(savedMediaID, video.id)
            XCTAssertEqual(savedAudio, AudioSettings(isMuted: true, volume: 0.6))
        }

        let image = MediaItem(url: directory.appendingPathComponent("still.png"),
                              kind: .image, width: 64, height: 64)
        let entry = PlaylistEntry(mediaID: image.id)
        XCTAssertTrue(model.mutate {
            $0.media.append(image)
            $0.playlists[0].entries = [entry]
            $0.displays = [DisplayBinding(id: screenID, playlistID: $0.playlists[0].id,
                                          currentEntryID: entry.id)]
        })
        XCTAssertTrue(model.currentWallpaperAudioTargets.isEmpty)
    }

    func testApplyingPlaylistToDisconnectedDisplayDoesNotChangeLibrary() throws {
        try verifyDisconnectedDisplayApplication { model, _ in
            model.applyPlaylist(model.library.playlists[0].id, displayID: "disconnected-display", fit: .fit)
        }
    }

    func testApplyingMediaToDisconnectedDisplayDoesNotCreatePlaylist() throws {
        try verifyDisconnectedDisplayApplication { model, item in
            model.applyMedia(item, displayID: "disconnected-display", fit: .fit)
        }
    }

    func testSameMediaHasIndependentPlaylistAudioAndPreviewSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail(error.localizedDescription) } }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let item = MediaItem(url: URL(fileURLWithPath: "/video.mov"), kind: .video, width: 64, height: 64)
        var library = Library.empty
        library.media = [item]
        let first = PlaylistEntry(mediaID: item.id)
        let second = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.8))
        library.playlists[0].entries = [first]
        library.playlists.append(Playlist(name: "second", entries: [second]))
        try store.save(library)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        model.updateEntryAudio(AudioSettings(isMuted: true, volume: 0.25), playlistID: library.playlists[0].id, entryID: first.id)
        XCTAssertNil(model.errorMessage)
        let restored = try store.load()
        XCTAssertEqual(restored.playlists[0].entries[0].audio, AudioSettings(isMuted: true, volume: 0.25))
        XCTAssertEqual(restored.playlists[1].entries[0].audio, AudioSettings(volume: 0.8))
        XCTAssertTrue(restored.settings.isMuted)
        model.selectedMediaID = item.id
        model.section = .playlist(library.playlists[0].id); model.selectedEntryID = first.id
        XCTAssertEqual(model.selectedEntryAudio, restored.playlists[0].entries[0].audio)
        model.section = .playlist(library.playlists[1].id); model.selectedEntryID = second.id
        XCTAssertEqual(model.selectedEntryAudio, restored.playlists[1].entries[0].audio)
        let saved = try Data(contentsOf: store.url)
        model.updateEntryAudio(AudioSettings(volume: 2), playlistID: library.playlists[0].id, entryID: first.id)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: store.url), saved)
        XCTAssertEqual(model.library, restored)
    }

    private func verifyDisconnectedDisplayApplication(_ apply: (AppModel, MediaItem) -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Temporary library cleanup failed: \(error)") }
        }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        var library = Library.empty
        library.media = [item]
        library.playlists[0].entries = [PlaylistEntry(mediaID: item.id)]
        library.displays = [DisplayBinding(id: "disconnected-display", playlistID: library.playlists[0].id)]
        try store.save(library)
        let originalData = try Data(contentsOf: store.url)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        XCTAssertFalse(model.displays.contains { $0.id == "disconnected-display" })
        apply(model, item)
        XCTAssertEqual(model.errorMessage, "目标显示器已断开，请重新选择显示器。")
        XCTAssertEqual(model.library, library)
        XCTAssertEqual(try Data(contentsOf: store.url), originalData)
    }
}
