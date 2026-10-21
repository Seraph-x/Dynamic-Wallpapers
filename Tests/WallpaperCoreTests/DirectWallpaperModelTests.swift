import XCTest
@testable import WallpaperCore

final class DirectWallpaperModelTests: XCTestCase {
    private var directory: URL!
    private let mediaID = UUID()
    private let playlistID = UUID()
    private let entryID = UUID()
    private let groupID = UUID()
    private var url: URL { directory.appendingPathComponent("library-extended.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testLoadsVersionTwoPlaylistBindingWithoutRewritingFile() throws {
        let original = try fixture(version: 2, displays: [legacyBinding()])
        try original.write(to: url)
        let loaded = try LibraryStore(url: url).load()
        XCTAssertEqual(loaded.version, 3)
        XCTAssertEqual(loaded.displays[0].playlistID, playlistID)
        XCTAssertEqual(loaded.displays[0].currentEntryID, entryID)
        XCTAssertEqual(loaded.displays[0].groupID, groupID)
        XCTAssertEqual(loaded.displays[0].fit, .fit)
        XCTAssertEqual(loaded.playlists[0].entries[0].audio.volume, 0.37)
        XCTAssertEqual(try Data(contentsOf: url), original)
        try LibraryStore(url: url).save(loaded)
        XCTAssertEqual(try LibraryStore(url: url).load(), loaded)
    }

    func testDirectWallpaperRoundTripsWithoutAnyPlaylist() throws {
        try fixture(displays: [directBinding()], hasPlaylist: false).write(to: url)
        let store = LibraryStore(url: url)
        let loaded = try store.load()
        XCTAssertTrue(loaded.playlists.isEmpty)
        XCTAssertNil(loaded.displays[0].currentEntryID)
        try store.save(loaded)
        XCTAssertEqual(try store.load(), loaded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let binding = try XCTUnwrap((json["displays"] as? [[String: Any]])?.first)
        XCTAssertNil(binding["playlistID"])
        let source = try XCTUnwrap(binding["source"] as? [String: Any])
        XCTAssertEqual(source["kind"] as? String, "media")
        XCTAssertEqual(source["mediaID"] as? String, mediaID.uuidString)
        XCTAssertEqual((source["audio"] as? [String: Any])?["volume"] as? Double, 0.25)
    }

    func testRejectsBothSourceAndLegacyPlaylistID() throws {
        var binding = legacyBinding()
        binding["source"] = ["kind": "playlist", "playlistID": playlistID.uuidString]
        let data = try JSONSerialization.data(withJSONObject: binding)
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayBinding.self, from: data))
    }

    func testRejectsMissingDirectMediaReference() throws {
        var binding = directBinding()
        binding["source"] = directSource(mediaID: UUID())
        let library = try JSONDecoder().decode(Library.self, from: fixture(displays: [binding]))
        XCTAssertThrowsError(try library.validate())
    }

    func testRejectsInvalidDirectAudio() throws {
        var binding = directBinding()
        binding["source"] = directSource(volume: 1.1)
        let library = try JSONDecoder().decode(Library.self, from: fixture(displays: [binding]))
        XCTAssertThrowsError(try library.validate())
    }

    func testRejectsPlaylistCursorOnDirectWallpaper() throws {
        var binding = directBinding()
        binding["currentEntryID"] = entryID.uuidString
        let library = try JSONDecoder().decode(Library.self, from: fixture(displays: [binding]))
        XCTAssertThrowsError(try library.validate())
    }

    func testSynchronizedDirectDisplaysMustHaveIdenticalAudio() throws {
        var other = directBinding(id: "B")
        other["source"] = directSource(volume: 0.75)
        let library = try JSONDecoder().decode(Library.self, from: fixture(displays: [directBinding(), other]))
        XCTAssertThrowsError(try library.validate())
    }

    func testSynchronizedGroupCannotMixDirectWallpaperAndPlaylist() throws {
        let library = try JSONDecoder().decode(Library.self,
            from: fixture(displays: [directBinding(id: "B"), legacyBinding()]))
        XCTAssertThrowsError(try library.validate())
    }

    func testSchemaTwoCannotContainDirectSource() throws {
        let bytes = try fixture(version: 2, displays: [directBinding()])
        try bytes.write(to: url)
        XCTAssertThrowsError(try LibraryStore(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testInvalidLegacyCursorIsRejectedBeforeUpgrade() throws {
        var binding = legacyBinding()
        binding["currentEntryID"] = UUID().uuidString
        let bytes = try fixture(version: 2, displays: [binding])
        try bytes.write(to: url)
        XCTAssertThrowsError(try LibraryStore(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testUnknownSchemaIsReportedWithoutRewriting() throws {
        let bytes = try fixture(version: 99, displays: [legacyBinding()])
        try bytes.write(to: url)
        XCTAssertThrowsError(try LibraryStore(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testBatchRemovalClearsDirectBindingsAndPreservesOtherSources() throws {
        var library = try JSONDecoder().decode(Library.self, from: fixture(displays: [directBinding()]))
        let other = MediaItem(url: directory.appendingPathComponent("other.png"), kind: .image, width: 32, height: 32)
        library.media.append(other)
        let direct = DisplayBinding(id: "B", source: .media(other.id, audio: AudioSettings()))
        let playlist = DisplayBinding(id: "C", playlistID: playlistID, currentEntryID: entryID)
        library.displays += [direct, playlist]
        let result = try BatchOperation.removeMedia(ids: [mediaID]).applying(to: library)
        XCTAssertEqual(result.displays.map(\.id), ["B", "C"])
        XCTAssertEqual(result.displays[0], direct)
        XCTAssertNil(result.displays[1].currentEntryID)
        XCTAssertEqual(result.playlists.count, 1)
        XCTAssertTrue(result.playlists[0].entries.isEmpty)
        XCTAssertEqual(library.displays.count, 3)
    }

    func testDirectSourceRejectsIncompleteConflictingAndUnknownEncoding() throws {
        var missingAudio = directSource()
        missingAudio.removeValue(forKey: "audio")
        var nullAudio = directSource()
        nullAudio["audio"] = NSNull()
        var conflicting = directSource()
        conflicting["playlistID"] = playlistID.uuidString
        var unknown = directSource()
        unknown["kind"] = "unavailable"
        for source in [missingAudio, nullAudio, conflicting, unknown] {
            let bytes = try JSONSerialization.data(withJSONObject: source)
            XCTAssertThrowsError(try JSONDecoder().decode(DisplaySource.self, from: bytes))
        }
    }

    func testNullSourceCannotUseTheLegacyPlaylistBinding() throws {
        var binding = legacyBinding()
        binding["source"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(DisplayBinding.self,
            from: JSONSerialization.data(withJSONObject: binding)))
    }

    func testFailedUpgradeSavePreservesTheVersionTwoFile() throws {
        let original = try fixture(version: 2, displays: [legacyBinding()])
        try original.write(to: url)
        let store = LibraryStore(url: url)
        let upgraded = try store.load()
        XCTAssertEqual(upgraded.version, 3)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            catch { XCTFail(error.localizedDescription) }
        }
        XCTAssertThrowsError(try store.save(upgraded))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try JSONDecoder().decode(Library.self, from: original).version, 2)
    }

    private func legacyBinding() -> [String: Any] {
        ["id": "A", "playlistID": playlistID.uuidString, "currentEntryID": entryID.uuidString,
         "fit": "fit", "groupID": groupID.uuidString]
    }

    private func directSource(mediaID: UUID? = nil, volume: Double = 0.25) -> [String: Any] {
        ["kind": "media", "mediaID": (mediaID ?? self.mediaID).uuidString,
         "audio": ["isMuted": false, "volume": volume]]
    }

    private func directBinding(id: String = "A") -> [String: Any] {
        ["id": id, "source": directSource(), "fit": "fit", "groupID": groupID.uuidString]
    }

    private func fixture(version: Int = 3, displays: [[String: Any]], hasPlaylist: Bool = true) throws -> Data {
        let item = MediaItem(id: mediaID, url: directory.appendingPathComponent("movie.mov"), kind: .video,
                             width: 64, height: 64, duration: 2)
        var library = Library.empty
        library.version = version
        library.media = [item]
        library.playlists = hasPlaylist ? [Playlist(id: playlistID, name: "手工列表", entries: [
            PlaylistEntry(id: entryID, mediaID: mediaID, audio: AudioSettings(volume: 0.37))
        ])] : []
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any])
        json["displays"] = displays
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
}
