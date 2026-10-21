import XCTest
import WallpaperCore
import ScreenSaverCore

final class SourceRevisionTests: XCTestCase {
    private func revision(_ fixture: ProjectionFixture, settings: ScreenSaverSettings? = nil) throws -> ScreenSaverSourceRevision {
        let source = ScreenSaverSource.playlist(fixture.list.id)
        return try ScreenSaverSourceRevision(projection: ScreenSaverProjection(library: fixture.library, source: source),
                                              settings: settings ?? ScreenSaverSettings(source: source))
    }

    func testCanonicalRevisionIgnoresFavoritesDesktopProgressAndUnrelatedLibraryEdits() throws {
        var fixture = ProjectionFixture()
        let baseline = try revision(fixture)
        XCTAssertEqual(baseline, try revision(fixture))
        XCTAssertEqual(baseline.value.count, 64)
        fixture.library.media[0].isFavorite.toggle()
        fixture.library.media[3].isFavorite.toggle()
        fixture.library.media.reverse()
        fixture.library.settings.isMuted.toggle()
        fixture.library.displays[0].currentEntryID = fixture.list.entries[0].id
        fixture.library.displays[0].fit = .fill
        fixture.library.playlists.append(Playlist(name: "Unrelated list"))
        fixture.library.playlists[1].transition = 3
        XCTAssertEqual(baseline, try revision(fixture))
        XCTAssertEqual(try JSONDecoder().decode(ScreenSaverSourceRevision.self, from: JSONEncoder().encode(baseline)), baseline)
    }

    func testRelatedSourceChangesProduceANewRevision() throws {
        let mutations: [(inout Library) -> Void] = [
            { $0.playlists[0].name = "Renamed" },
            { $0.playlists[0].mode = .shuffle },
            { $0.playlists[0].transition = 1.2 },
            { $0.playlists[0].entries[0].timing.seconds = 14 },
            { $0.playlists[0].entries[0].audio.volume = 0.9 },
            { $0.playlists[0].entries.swapAt(0, 3) },
            { $0.playlists[0].entries.append(PlaylistEntry(mediaID: $0.media[0].id)) },
            { let item = $0.media[3]; $0.media[3] = MediaItem(id: item.id, url: item.url, kind: item.kind, width: 128, height: item.height) }
        ]
        for mutation in mutations {
            var fixture = ProjectionFixture()
            let before = try revision(fixture)
            mutation(&fixture.library)
            XCTAssertNotEqual(before, try revision(fixture))
        }
    }

    func testPlaybackOverridesAffectRevisionButTheConsentReceiptDoesNot() throws {
        let fixture = ProjectionFixture()
        let source = ScreenSaverSource.playlist(fixture.list.id)
        let baseline = try revision(fixture)
        XCTAssertNotEqual(baseline, try revision(fixture, settings: ScreenSaverSettings(source: source, isMuted: false)))
        XCTAssertNotEqual(baseline, try revision(fixture, settings: ScreenSaverSettings(source: source, fit: .fit)))
        let projection = try ScreenSaverProjection(library: fixture.library, source: source)
        XCTAssertEqual(baseline, try revision(fixture, settings: ScreenSaverSettings(source: source,
            consent: ScreenSaverConsent(acknowledging: projection))))
        XCTAssertThrowsError(try revision(fixture, settings: ScreenSaverSettings(source: .media(fixture.image.id))))
    }

    func testSingleMediaRevisionIgnoresOtherListsAndDefersFileIOToPublisher() throws {
        var fixture = ProjectionFixture()
        let source = ScreenSaverSource.media(fixture.image.id)
        let settings = ScreenSaverSettings(source: source)
        let before = try ScreenSaverSourceRevision(projection: ScreenSaverProjection(library: fixture.library, source: source), settings: settings)
        fixture.library.playlists[0].entries.reverse()
        let after = try ScreenSaverSourceRevision(projection: ScreenSaverProjection(library: fixture.library, source: source), settings: settings)
        XCTAssertEqual(before, after)
        // Fixture URLs intentionally do not exist: source-byte validation belongs to the publisher, not this pure projection.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.image.url.path))
    }

    func testMalformedRevisionCannotBeDecoded() throws {
        for value in ["", "bad", String(repeating: "g", count: 64), String(repeating: "A", count: 64)] {
            let data = try JSONSerialization.data(withJSONObject: ["value": value])
            XCTAssertThrowsError(try JSONDecoder().decode(ScreenSaverSourceRevision.self, from: data))
        }
    }
}
