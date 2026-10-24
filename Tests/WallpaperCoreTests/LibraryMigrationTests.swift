import XCTest
@testable import WallpaperCore

final class LibraryMigrationTests: XCTestCase {
    private var directory: URL!
    private var legacy: URL { directory.appendingPathComponent("library.json") }
    private var extended: URL { directory.appendingPathComponent("library-extended.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func writeLegacy() throws -> Library {
        var library = Library.empty
        library.version = 1
        let item = MediaItem(url: directory.appendingPathComponent("movie.mov"), kind: .video,
                             width: 320, height: 180, duration: 2)
        library.media = [item]
        library.playlists[0].entries = [PlaylistEntry(mediaID: item.id, audio: AudioSettings(isMuted: true, volume: 0.37))]
        library.displays = [DisplayBinding(id: "display", playlistID: library.playlists[0].id,
                                          currentEntryID: library.playlists[0].entries[0].id)]
        library.settings.isMuted = false
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as? [String: Any])
        let binding = library.displays[0]
        json["displays"] = [["id": binding.id, "playlistID": library.playlists[0].id.uuidString,
                             "currentEntryID": library.playlists[0].entries[0].id.uuidString,
                             "fit": binding.fit.rawValue, "groupID": binding.groupID.uuidString]]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: legacy)
        return library
    }

    func testCopiesValidatedLegacyPreservingIDsAudioAndOriginalBytes() throws {
        var expected = try writeLegacy()
        let bytes = try Data(contentsOf: legacy)
        expected.version = Library.currentVersion
        let store = LibraryStore(url: extended, legacyURL: legacy)
        XCTAssertEqual(try store.load(), expected)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try JSONDecoder().decode(Library.self, from: Data(contentsOf: extended)), expected)
        var edited = expected
        edited.playlists[0].name = "新版编辑"
        try store.save(edited)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try store.load(), edited)
    }

    func testCorruptExtendedNeverFallsBackToValidLegacyOrOverwritesEitherFile() throws {
        _ = try writeLegacy()
        let oldBytes = try Data(contentsOf: legacy)
        let broken = Data("{broken".utf8)
        try broken.write(to: extended)
        XCTAssertThrowsError(try LibraryStore(url: extended, legacyURL: legacy).load())
        XCTAssertEqual(try Data(contentsOf: extended), broken)
        XCTAssertEqual(try Data(contentsOf: legacy), oldBytes)
    }

    func testInvalidLegacyDoesNotLeaveNewLibrary() throws {
        var invalid = try writeLegacy()
        invalid.playlists[0].entries[0].audio.volume = 2
        let bytes = try JSONEncoder().encode(invalid)
        try bytes.write(to: legacy)
        XCTAssertThrowsError(try LibraryStore(url: extended, legacyURL: legacy).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: extended.path))
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }

    func testMigrationWriteFailureLeavesSourceAndNoPartialLibrary() throws {
        _ = try writeLegacy()
        let bytes = try Data(contentsOf: legacy)
        let lockedDirectory = directory.appendingPathComponent("read-only")
        try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedDirectory.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedDirectory.path) }
            catch { XCTFail("Unable to restore test directory permissions: \(error)") }
        }
        let target = lockedDirectory.appendingPathComponent("library-extended.json")
        XCTAssertThrowsError(try LibraryStore(url: target, legacyURL: legacy).load())
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lockedDirectory.path), [])
    }

    func testFreshInstallCreatesCurrentSchemaWithoutLegacyFile() throws {
        let library = try LibraryStore(url: extended, legacyURL: legacy).load()
        XCTAssertEqual(library.version, Library.currentVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try LibraryStore(url: extended).load(), library)
    }

    func testRejectsWrongVersionInEitherLocation() throws {
        var library = try writeLegacy()
        try JSONEncoder().encode(library).write(to: extended)
        XCTAssertThrowsError(try LibraryStore(url: extended, legacyURL: legacy).load())
        try FileManager.default.removeItem(at: extended)
        library.version = 2
        try JSONEncoder().encode(library).write(to: legacy)
        XCTAssertThrowsError(try LibraryStore(url: extended, legacyURL: legacy).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: extended.path))
    }

    func testDanglingExtendedSymlinkIsAnErrorNotMissingLibrary() throws {
        _ = try writeLegacy()
        let absent = directory.appendingPathComponent("absent")
        try FileManager.default.createSymbolicLink(at: extended, withDestinationURL: absent)
        XCTAssertThrowsError(try LibraryStore(url: extended, legacyURL: legacy).load())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: extended.path), absent.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testExclusiveCommitNeverReplacesFileCreatedBeforeCommit() throws {
        let staged = directory.appendingPathComponent("staged")
        try Data("candidate".utf8).write(to: staged)
        let existing = Data("other-writer".utf8)
        try existing.write(to: extended)
        XCTAssertThrowsError(try ExclusiveFileCommit.commit(staged: staged, destination: extended))
        XCTAssertEqual(try Data(contentsOf: extended), existing)
        XCTAssertEqual(try Data(contentsOf: staged), Data("candidate".utf8))
    }
}
