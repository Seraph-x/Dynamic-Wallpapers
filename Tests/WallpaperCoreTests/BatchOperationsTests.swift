import XCTest
@testable import WallpaperCore

final class BatchOperationsTests: XCTestCase {
    private func fixture() -> Library {
        var library = Library.empty
        library.media = [
            MediaItem(url: URL(fileURLWithPath: "/first.mov"), kind: .video, width: 64, height: 64, duration: 10),
            MediaItem(url: URL(fileURLWithPath: "/second.png"), kind: .image, width: 64, height: 64),
            MediaItem(url: URL(fileURLWithPath: "/third.gif"), kind: .animatedImage, width: 64, height: 64, duration: 2)
        ]
        library.playlists[0].entries = [
            PlaylistEntry(mediaID: library.media[0].id, audio: AudioSettings(isMuted: true, volume: 0.2)),
            PlaylistEntry(mediaID: library.media[0].id, audio: AudioSettings(volume: 0.8)),
            PlaylistEntry(mediaID: library.media[1].id),
            PlaylistEntry(mediaID: library.media[2].id)
        ]
        library.playlists.append(Playlist(name: "Other", entries: library.playlists[0].entries.map {
            PlaylistEntry(mediaID: $0.mediaID, timing: $0.timing, audio: $0.audio)
        }))
        return library
    }

    func testAppendUsesLibraryOrderAndKeepsExistingDuplicates() throws {
        let original = fixture()
        let result = try BatchOperation.addMedia(ids: Set(original.media.map(\.id)), playlistID: original.playlists[0].id).applying(to: original)
        XCTAssertEqual(Array(result.playlists[0].entries.prefix(4)), original.playlists[0].entries)
        let added = Array(result.playlists[0].entries.suffix(3))
        XCTAssertEqual(added.map(\.mediaID), original.media.map(\.id))
        XCTAssertEqual(Set(result.playlists[0].entries.map(\.id)).count, 7)
        XCTAssertTrue(added.allSatisfy { $0.audio == AudioSettings() && $0.timing == EntryTiming() })
        XCTAssertEqual(result.playlists[1], original.playlists[1])
    }

    func testFavoriteIsAnAssignmentOnSelectedMediaOnly() throws {
        let original = fixture()
        let ids: Set<UUID> = [original.media[0].id, original.media[1].id]
        let favorite = BatchOperation.favoriteMedia(ids: ids, value: true)
        let result = try favorite.applying(to: favorite.applying(to: original))
        XCTAssertEqual(result.media.map(\.isFavorite), [true, true, false])
        let cleared = try BatchOperation.favoriteMedia(ids: ids, value: false).applying(to: result)
        XCTAssertEqual(cleared, original)
    }

    func testRemoveMediaClearsAllReferencesAndCurrent() throws {
        var original = fixture()
        original.displays = original.playlists.map { DisplayBinding(id: $0.name, playlistID: $0.id, currentEntryID: $0.entries[0].id) }
        let result = try BatchOperation.removeMedia(ids: [original.media[0].id]).applying(to: original)
        XCTAssertEqual(result.media, Array(original.media.dropFirst()))
        XCTAssertTrue(result.playlists.allSatisfy { $0.entries.count == 2 })
        XCTAssertTrue(result.displays.allSatisfy { $0.currentEntryID == nil })
        XCTAssertEqual(result.settings, original.settings)
    }

    func testVolumePatchPreservesMuteTimingAndOtherEntries() throws {
        let original = fixture(), list = original.playlists[0]
        let result = try BatchOperation.editEntries(playlistID: list.id, ids: [list.entries[0].id], patch: EntryBatchPatch(volume: 0.6)).applying(to: original)
        XCTAssertEqual(result.playlists[0].entries[0].audio, AudioSettings(isMuted: true, volume: 0.6))
        XCTAssertEqual(result.playlists[0].entries[0].timing, list.entries[0].timing)
        XCTAssertEqual(Array(result.playlists[0].entries.dropFirst()), Array(list.entries.dropFirst()))
        XCTAssertEqual(result.playlists[1], original.playlists[1])
        XCTAssertEqual(result.settings, original.settings)
    }

    func testMixedMediaPatchChangesTimingForAllAndAudioForVideosOnly() throws {
        let original = fixture(), list = original.playlists[0]
        let timing = EntryTiming(mode: .loops, seconds: 7, loops: 3)
        let result = try BatchOperation.editEntries(playlistID: list.id, ids: Set(list.entries.map(\.id)),
            patch: EntryBatchPatch(timing: timing, isMuted: false, volume: 0.4)).applying(to: original)
        let entries = result.playlists[0].entries
        XCTAssertTrue(entries.allSatisfy { $0.timing == timing })
        XCTAssertEqual(entries[0].audio, AudioSettings(volume: 0.4))
        XCTAssertEqual(entries[1].audio, AudioSettings(volume: 0.4))
        XCTAssertEqual(entries[2].audio, list.entries[2].audio)
        XCTAssertEqual(entries[3].audio, list.entries[3].audio)
        XCTAssertEqual(entries[2].timing.duration(mediaDuration: nil), 21)
        let full = try BatchOperation.editEntries(playlistID: list.id, ids: [entries[2].id],
            patch: EntryBatchPatch(timing: EntryTiming(mode: .full, seconds: 7))).applying(to: result)
        XCTAssertEqual(full.playlists[0].entries[2].timing.duration(mediaDuration: nil), 7)
    }

    func testMutePatchPreservesVolume() throws {
        let original = fixture(), list = original.playlists[0]
        let result = try BatchOperation.editEntries(playlistID: list.id, ids: [list.entries[1].id], patch: EntryBatchPatch(isMuted: true)).applying(to: original)
        XCTAssertEqual(result.playlists[0].entries[1].audio, AudioSettings(isMuted: true, volume: 0.8))
    }

    func testRemoveEntriesOnlyAffectsChosenListAndKeepsMedia() throws {
        var original = fixture()
        let list = original.playlists[0]
        original.displays = [DisplayBinding(id: "offline", playlistID: list.id, currentEntryID: list.entries[0].id)]
        let result = try BatchOperation.removeEntries(playlistID: list.id, ids: Set(list.entries.map(\.id))).applying(to: original)
        XCTAssertTrue(result.playlists[0].entries.isEmpty)
        XCTAssertNil(result.displays[0].currentEntryID)
        XCTAssertEqual(result.playlists[1], original.playlists[1])
        XCTAssertEqual(result.media, original.media)
    }

    func testRejectsEmptyStaleAndWrongListSelections() {
        let original = fixture(), list = original.playlists[0]
        let operations: [BatchOperation] = [
            .favoriteMedia(ids: [], value: true), .removeMedia(ids: [UUID()]),
            .addMedia(ids: [original.media[0].id, UUID()], playlistID: list.id),
            .addMedia(ids: [original.media[0].id], playlistID: UUID()),
            .removeEntries(playlistID: list.id, ids: []),
            .removeEntries(playlistID: list.id, ids: [list.entries[0].id, UUID()]),
            .editEntries(playlistID: list.id, ids: [original.playlists[1].entries[0].id], patch: EntryBatchPatch(isMuted: true))
        ]
        for operation in operations { XCTAssertThrowsError(try operation.applying(to: original)) }
    }

    func testRejectsInvalidOrInapplicablePatches() {
        let original = fixture(), list = original.playlists[0]
        let patches = [EntryBatchPatch(), EntryBatchPatch(volume: .nan), EntryBatchPatch(volume: -0.1),
            EntryBatchPatch(volume: 1.1), EntryBatchPatch(timing: EntryTiming(seconds: 0)),
            EntryBatchPatch(timing: EntryTiming(mode: .loops, seconds: Double(Int64.max), loops: 2))]
        for patch in patches {
            XCTAssertThrowsError(try BatchOperation.editEntries(playlistID: list.id, ids: [list.entries[0].id], patch: patch).applying(to: original))
        }
        XCTAssertThrowsError(try BatchOperation.editEntries(playlistID: list.id, ids: [list.entries[2].id], patch: EntryBatchPatch(isMuted: true)).applying(to: original))
    }
}
