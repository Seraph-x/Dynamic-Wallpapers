import XCTest
@testable import WallpaperCore

final class LibraryStoreTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testRoundTripAndInitialLibrary() throws {
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        let library = try store.load()
        XCTAssertEqual(library.playlists.count, 1)
        try store.save(library)
        XCTAssertEqual(try store.load(), library)
    }

    func testCorruptFileIsReportedAndUntouched() throws {
        let url = directory.appendingPathComponent("library.json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try LibraryStore(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testInvalidReferencesCannotBeSaved() throws {
        var library = Library.empty
        library.playlists[0].entries = [PlaylistEntry(mediaID: UUID())]
        XCTAssertThrowsError(try LibraryStore(url: directory.appendingPathComponent("library.json")).save(library))
    }

    func testTimingRejectsNonFiniteAndZero() throws {
        XCTAssertThrowsError(try EntryTiming(mode: .seconds, seconds: .infinity).validate())
        XCTAssertThrowsError(try EntryTiming(mode: .loops, loops: 0).validate())
        XCTAssertEqual(EntryTiming(mode: .loops, loops: 3).duration(mediaDuration: 4), 12)
    }

    func testUnrepresentableClockDurationsAreRejected() {
        XCTAssertThrowsError(try EntryTiming(seconds: 1e20).validate())
    }

    func testConflictingSynchronizedGroupIsRejected() throws {
        var library = Library.empty
        let second = Playlist(name: "second")
        library.playlists.append(second)
        let group = UUID()
        library.displays = [DisplayBinding(id: "one", playlistID: library.playlists[0].id, groupID: group),
                            DisplayBinding(id: "two", playlistID: second.id, groupID: group)]
        XCTAssertThrowsError(try library.validate())
    }
}
