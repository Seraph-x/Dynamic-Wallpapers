import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class DirectWallpaperAppModelTests: XCTestCase {
    func testApplyingMediaDoesNotCreateOrReuseAPlaylist() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let originalLists = fixture.model.library.playlists
        fixture.model.applyMedia(fixture.item, displayID: fixture.screenID, fit: .fit)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.library.playlists, originalLists)
        let restored = try fixture.store.load()
        XCTAssertEqual(restored, fixture.model.library)
        let binding = try XCTUnwrap(restored.displays.first { $0.id == fixture.screenID })
        XCTAssertNil(binding.currentEntryID)
        XCTAssertEqual(binding.fit, .fit)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        XCTAssertNil(json["playlistID"])
        XCTAssertEqual((json["source"] as? [String: Any])?["mediaID"] as? String, fixture.item.id.uuidString)
    }

    func testApplyingUnknownMediaLeavesLibraryAndFileUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = fixture.model.library
        let bytes = try Data(contentsOf: fixture.store.url)
        let unknown = MediaItem(url: URL(fileURLWithPath: "/removed.png"), kind: .image, width: 32, height: 32)
        fixture.model.applyMedia(unknown, displayID: fixture.screenID, fit: .fill)
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url), bytes)
    }

    func testApplyingMediaDoesNotBindAnExistingRepeatOnePlaylist() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.mutate { $0.playlists[0].mode = .repeatOne })
        let originalLists = fixture.model.library.playlists
        fixture.model.applyMedia(fixture.item, displayID: fixture.screenID, fit: .fill)
        XCTAssertEqual(fixture.model.library.playlists, originalLists)
        let binding = try XCTUnwrap(fixture.model.library.displays.first)
        XCTAssertNil(binding.playlistID)
        XCTAssertEqual(binding.source.mediaID, fixture.item.id)
    }

    func testApplyingToAllDisplaysCreatesOneDirectSynchronizedGroup() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let originalLists = fixture.model.library.playlists
        fixture.model.applyMedia(fixture.item, displayID: nil, fit: .fit)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.library.playlists, originalLists)
        let bindings = fixture.model.library.displays
        XCTAssertEqual(Set(bindings.map(\.id)), Set(fixture.model.displays.map(\.id)))
        XCTAssertEqual(Set(bindings.map(\.groupID)).count, 1)
        XCTAssertTrue(bindings.allSatisfy { $0.source.mediaID == fixture.item.id && $0.currentEntryID == nil })
        XCTAssertEqual(try fixture.store.load(), fixture.model.library)
    }

    func testRemovingDirectMediaClearsItsBindingsWithoutDeletingPlaylists() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.mutate {
            $0.displays = [DisplayBinding(id: "offline", source: .media(fixture.item.id, audio: AudioSettings()))]
        })
        fixture.model.removeMedia(fixture.item.id)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertTrue(fixture.model.library.displays.isEmpty)
        XCTAssertTrue(fixture.model.library.media.isEmpty)
        XCTAssertEqual(fixture.model.library.playlists.count, 1)
        XCTAssertEqual(try fixture.store.load(), fixture.model.library)
    }

    func testFailedDirectApplicationDoesNotLeaveAnOrphanPlaylist() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let original = fixture.model.library
        let bytes = try Data(contentsOf: fixture.store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path) }
            catch { XCTFail(error.localizedDescription) }
        }
        fixture.model.applyMedia(fixture.item, displayID: fixture.screenID, fit: .fit)
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url), bytes)
    }

    func testDirectFirstFrameDoesNotRewriteTheSavedLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 180, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: fixture.item.url)
        fixture.model.applyMedia(fixture.item, displayID: fixture.screenID, fit: .fill)
        let before = try FileManager.default.attributesOfItem(atPath: fixture.store.url.path)[.systemFileNumber] as? NSNumber
        let deadline = ContinuousClock.now + .seconds(2)
        while !fixture.model.statuses.values.contains(where: { $0.hasPrefix("正在播放") }) {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Direct wallpaper did not display") }
            try await Task.sleep(for: .milliseconds(5))
        }
        let after = try FileManager.default.attributesOfItem(atPath: fixture.store.url.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(try XCTUnwrap(before), try XCTUnwrap(after), "First-frame commit must not atomically replace the saved direct binding")
        XCTAssertNil(fixture.model.library.displays.first?.currentEntryID)
        XCTAssertEqual(try fixture.store.load(), fixture.model.library)
        try await fixture.model.shutdownAndWait()
    }

    func testDirectAudioUpdatesOnlyItsSynchronizedGroup() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let group = UUID()
        let source = DisplaySource.media(fixture.item.id, audio: AudioSettings(volume: 0.25))
        let independent = DisplayBinding(id: "C", source: .media(fixture.item.id, audio: AudioSettings(volume: 0.9)))
        XCTAssertTrue(fixture.model.mutate {
            $0.displays = [DisplayBinding(id: "A", source: source, groupID: group),
                           DisplayBinding(id: "B", source: source, groupID: group), independent]
        })
        let originalLists = fixture.model.library.playlists
        let audio = AudioSettings(isMuted: true, volume: 0.45)
        fixture.model.updateDirectAudio(audio, groupID: group)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertTrue(fixture.model.library.displays.prefix(2).allSatisfy { $0.source == .media(fixture.item.id, audio: audio) })
        XCTAssertEqual(fixture.model.library.displays[2], independent)
        XCTAssertEqual(fixture.model.library.playlists, originalLists)
        XCTAssertEqual(try fixture.store.load(), fixture.model.library)
    }

    func testInvalidDirectAudioAndMissingGroupLeaveTheLibraryUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let binding = DisplayBinding(id: "offline", source: .media(fixture.item.id, audio: AudioSettings()))
        XCTAssertTrue(fixture.model.mutate { $0.displays = [binding] })
        let original = fixture.model.library
        let bytes = try Data(contentsOf: fixture.store.url)
        fixture.model.updateDirectAudio(AudioSettings(volume: 2), groupID: binding.groupID)
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url), bytes)
        fixture.model.failure = nil
        fixture.model.updateDirectAudio(AudioSettings(), groupID: UUID())
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url), bytes)
    }

    func testInvalidApplicationAudioCannotReplaceExistingBinding() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.model.applyPlaylist(fixture.model.library.playlists[0].id, displayID: fixture.screenID, fit: .fit)
        let original = fixture.model.library
        let bytes = try Data(contentsOf: fixture.store.url)
        fixture.model.applyMedia(fixture.item, displayID: fixture.screenID, fit: .fill, audio: AudioSettings(volume: -0.1))
        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url), bytes)
    }

    func testNextRequiresAConnectedPlaylistGroup() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.model.applyMedia(fixture.item, displayID: fixture.screenID, fit: .fill)
        let directGroup = try XCTUnwrap(fixture.model.library.displays.first?.groupID)
        XCTAssertTrue(fixture.model.mutate {
            $0.displays.append(DisplayBinding(id: "offline", playlistID: $0.playlists[0].id))
        })
        XCTAssertFalse(fixture.model.canAdvance())
        XCTAssertFalse(fixture.model.canAdvance(groupID: directGroup))
        fixture.model.applyPlaylist(fixture.model.library.playlists[0].id, displayID: fixture.screenID, fit: .fill)
        let activeGroup = try XCTUnwrap(fixture.model.library.displays.first { $0.id == fixture.screenID }?.groupID)
        XCTAssertTrue(fixture.model.canAdvance())
        XCTAssertTrue(fixture.model.canAdvance(groupID: activeGroup))
        XCTAssertFalse(fixture.model.canAdvance(groupID: directGroup))
        XCTAssertFalse(fixture.model.canAdvance(groupID: UUID()))
    }

    func testDeletingAPlaylistKeepsTheIndependentDirectBinding() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let binding = DisplayBinding(id: "offline", source: .media(fixture.item.id, audio: AudioSettings(volume: 0.6)))
        XCTAssertTrue(fixture.model.mutate { $0.displays = [binding] })
        fixture.model.deletePlaylist(fixture.model.library.playlists[0].id)
        XCTAssertEqual(fixture.model.library.displays, [binding])
        XCTAssertTrue(fixture.model.library.playlists.isEmpty)
        let reopened = AppModel(store: fixture.store)
        defer { reopened.shutdown() }
        XCTAssertFalse(reopened.loadFailed)
        XCTAssertEqual(reopened.library, fixture.model.library)
    }

    func testApplyingToOneDisplayPreservesTheOtherSynchronizedBinding() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let group = UUID()
        let source = DisplaySource.media(fixture.item.id, audio: AudioSettings(volume: 0.25))
        let other = DisplayBinding(id: "offline", source: source, fit: .fill, groupID: group)
        XCTAssertTrue(fixture.model.mutate {
            $0.displays = [DisplayBinding(id: fixture.screenID, source: source, groupID: group), other]
        })
        let audio = AudioSettings(volume: 0.5)
        fixture.model.applyMedia(fixture.item, displayID: fixture.screenID, fit: .fit, audio: audio)
        let updated = try XCTUnwrap(fixture.model.library.displays.first { $0.id == fixture.screenID })
        XCTAssertNotEqual(updated.groupID, group)
        XCTAssertEqual(updated.fit, .fit)
        XCTAssertEqual(updated.source, .media(fixture.item.id, audio: audio))
        XCTAssertEqual(fixture.model.library.displays.first { $0.id == other.id }, other)
        XCTAssertEqual(try fixture.store.load(), fixture.model.library)
    }

    @MainActor private struct Fixture {
        let directory: URL
        let store: LibraryStore
        let item: MediaItem
        let model: AppModel
        let screenID: String

        init() throws {
            _ = NSApplication.shared
            screenID = try XCTUnwrap(NSScreen.main?.wallpaperID)
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = LibraryStore(url: directory.appendingPathComponent("library.json"))
            item = MediaItem(url: directory.appendingPathComponent("wallpaper.png"), kind: .image, width: 32, height: 32)
            var library = Library.empty
            library.media = [item]
            library.playlists[0].entries = [PlaylistEntry(mediaID: item.id)]
            try store.save(library)
            model = AppModel(store: store)
        }

        func close() {
            model.shutdown()
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Temporary library cleanup failed: \(error)") }
        }
    }
}
