import XCTest
import WallpaperCore
import ScreenSaverCore

final class ProjectionTests: XCTestCase {
    func testSingleMediaUsesIndependentStableEntryWithoutChangingLibrary() throws {
        let fixture = ProjectionFixture()
        let before = try JSONEncoder().encode(fixture.library)
        let projection = try ScreenSaverProjection(library: fixture.library, source: .media(fixture.image.id))
        XCTAssertEqual(projection.source, .media(fixture.image.id))
        XCTAssertEqual(projection.media, [fixture.image])
        XCTAssertEqual(projection.entries.map(\.id), [fixture.image.id])
        XCTAssertEqual(projection.entries.map(\.mediaID), [fixture.image.id])
        XCTAssertEqual(projection.entries[0].audio, AudioSettings())
        XCTAssertEqual(projection.mode, .repeatOne)
        XCTAssertEqual(projection.transition, 0)
        XCTAssertTrue(projection.exclusions.isEmpty)
        try projection.validateForPublication(consent: nil)
        XCTAssertEqual(try JSONDecoder().decode(Library.self, from: before), fixture.library)
    }

    func testPlaylistRetainsOrderDuplicatesTimingAudioAndEveryMode() throws {
        for mode in PlaybackMode.allCases {
            var fixture = ProjectionFixture()
            fixture.library.playlists[0].mode = mode
            let before = fixture.library
            let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
            XCTAssertEqual(projection.entries, [fixture.list.entries[0], fixture.list.entries[2], fixture.list.entries[3]])
            XCTAssertEqual(projection.media, [fixture.image, fixture.animation])
            XCTAssertEqual(projection.mode, mode)
            XCTAssertEqual(projection.transition, fixture.list.transition)
            XCTAssertEqual(projection.exclusions.map(\.signature.entryID), [fixture.list.entries[1].id, fixture.list.entries[4].id])
            XCTAssertEqual(projection.exclusions.map(\.signature.reason), [.extendedBackend, .webContent])
            XCTAssertEqual(fixture.library, before)
        }
    }

    func testSupportUsesKindAndBackendNotExtension() throws {
        var fixture = ProjectionFixture()
        let native = MediaItem(url: URL(fileURLWithPath: "/screensaver-test/native.mkv"), kind: .video,
                               width: 64, height: 32, duration: 2)
        fixture.library.media.append(native)
        let projection = try ScreenSaverProjection(library: fixture.library, source: .media(native.id))
        XCTAssertEqual(projection.media, [native])
        XCTAssertTrue(projection.exclusions.isEmpty)
        let excluded = try ScreenSaverProjection(library: fixture.library, source: .media(fixture.extended.id))
        XCTAssertTrue(excluded.media.isEmpty)
        XCTAssertEqual(excluded.exclusions.first?.signature.reason, .extendedBackend)
        XCTAssertThrowsError(try excluded.validateForPublication(consent: ScreenSaverConsent(acknowledging: excluded))) {
            XCTAssertEqual($0 as? ScreenSaverProjectionError, .noSupportedMedia)
        }
    }

    func testMissingSourceEmptyListAndMissingReferencesAreNotExclusions() throws {
        var fixture = ProjectionFixture()
        for source in [ScreenSaverSource.media(UUID()), .playlist(UUID())] {
            XCTAssertThrowsError(try ScreenSaverProjection(library: fixture.library, source: source)) {
                XCTAssertEqual($0 as? ScreenSaverProjectionError, .sourceMissing(source))
            }
        }
        fixture.library.playlists[0].entries = []
        XCTAssertThrowsError(try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))) {
            XCTAssertEqual($0 as? ScreenSaverProjectionError, .emptySource)
        }
        let missing = UUID()
        fixture.library.playlists[0].entries = [PlaylistEntry(mediaID: missing)]
        XCTAssertThrowsError(try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))) {
            XCTAssertEqual($0 as? ScreenSaverProjectionError, .missingMedia(missing))
        }
    }

    func testAllUnsupportedStillExposesReasonsButCannotPublish() throws {
        var fixture = ProjectionFixture()
        let unsupportedIDs = Set([fixture.web.id, fixture.extended.id])
        fixture.library.playlists[0].entries.removeAll { !unsupportedIDs.contains($0.mediaID) }
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        XCTAssertEqual(projection.exclusions.count, 2)
        XCTAssertTrue(projection.entries.isEmpty)
        XCTAssertThrowsError(try projection.validateForPublication(consent: ScreenSaverConsent(acknowledging: projection))) {
            XCTAssertEqual($0 as? ScreenSaverProjectionError, .noSupportedMedia)
        }
    }

    func testInvalidNativeMetadataCannotBecomeAnApprovedExclusion() {
        let invalid = [
            MediaItem(url: URL(fileURLWithPath: "/bad.png"), kind: .image, width: 0, height: 1),
            MediaItem(url: URL(fileURLWithPath: "/bad.mov"), kind: .video, width: 1, height: 1),
            MediaItem(url: URL(fileURLWithPath: "/bad.mov"), kind: .video, width: 1, height: 1, duration: .nan),
            MediaItem(url: URL(fileURLWithPath: "/bad.mov"), kind: .video, width: 1, height: 1, duration: .infinity),
            MediaItem(url: URL(fileURLWithPath: "/bad.mov"), kind: .video, width: 1, height: 1, duration: 0),
            MediaItem(url: URL(string: "https://invalid.test/image.png")!, kind: .image, width: 1, height: 1),
            MediaItem(url: URL(fileURLWithPath: "/bad.png"), kind: .image, width: 1, height: 1, backend: .extended)
        ]
        for item in invalid {
            var library = Library()
            library.media = [item]
            XCTAssertThrowsError(try ScreenSaverProjection(library: library, source: .media(item.id)))
        }
    }

    func testInvalidVersionsDuplicateIDsAndNonFinitePlaybackValuesFail() {
        let mutations: [(inout Library) -> Void] = [
            { $0.version = Library.currentVersion + 1 },
            { $0.media.append($0.media[0]) },
            { $0.playlists.append($0.playlists[0]) },
            { $0.playlists[0].entries.append($0.playlists[0].entries[0]) },
            { $0.playlists[0].transition = .infinity },
            { $0.playlists[0].transition = -0.1 },
            { $0.playlists[0].entries[0].audio.volume = .nan },
            { $0.playlists[0].entries[0].audio.volume = 1.1 },
            { $0.playlists[0].entries[0].timing.seconds = .infinity },
            { $0.playlists[0].entries[0].timing.loops = 0 },
            { $0.playlists[0].entries[3].timing = EntryTiming(mode: .loops, loops: Int.max) }
        ]
        for mutate in mutations {
            var fixture = ProjectionFixture()
            mutate(&fixture.library)
            XCTAssertThrowsError(try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id)))
        }
    }

    func testProjectionRoundTripValidatesDecodedPlaybackValues() throws {
        let fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let data = try JSONEncoder().encode(projection)
        XCTAssertEqual(try JSONDecoder().decode(ScreenSaverProjection.self, from: data), projection)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["transition"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenSaverProjection.self,
            from: JSONSerialization.data(withJSONObject: json)))
    }

    func testSingleWebSourceExposesExclusionInsteadOfSynthesizingInvalidTiming() throws {
        let fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .media(fixture.web.id))
        XCTAssertTrue(projection.entries.isEmpty)
        XCTAssertEqual(projection.exclusions.first?.signature.reason, .webContent)
        XCTAssertThrowsError(try projection.validateForPublication(consent: ScreenSaverConsent(acknowledging: projection))) {
            XCTAssertEqual($0 as? ScreenSaverProjectionError, .noSupportedMedia)
        }
    }
}
