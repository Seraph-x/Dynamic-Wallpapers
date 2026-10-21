import XCTest
@testable import WallpaperCore

final class ExtendedMediaModelTests: XCTestCase {
    let root = URL(fileURLWithPath: "/tmp/wallpaper-project", isDirectory: true)
    func webpage() -> MediaItem {
        MediaItem(url: root.appendingPathComponent("index.html"), kind: .web, width: 640, height: 360,
                  backend: .web, webProject: WebProjectReference(root: root, entry: "index.html"))
    }
    func library(_ item: MediaItem) -> Library {
        var value = Library.empty
        value.media = [item]
        value.playlists[0].entries = [PlaylistEntry(mediaID: item.id)]
        return value
    }
    func testWebReferenceAndExplicitBackendRoundTrip() throws {
        let value = library(webpage())
        try value.validate()
        XCTAssertEqual(try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(value)), value)
        XCTAssertTrue(value.media[0].supportsAudio)
    }

    func testWebNameUsesProjectRootAndCustomNameRoundTrips() throws {
        let sourceRoot = root.deletingLastPathComponent().appendingPathComponent("forest-spirit")
        let source = MediaItem(url: sourceRoot.appendingPathComponent("index.html"), kind: .web,
                               width: 640, height: 360, backend: .web,
                               webProject: WebProjectReference(root: sourceRoot, entry: "index.html"),
                               origin: MediaOrigin(url: sourceRoot.appendingPathComponent("index.html"),
                                                   projectRoot: sourceRoot))
        XCTAssertEqual(source.name, "forest-spirit")
        var renamed = source
        renamed.customName = "林间精灵"
        XCTAssertEqual(renamed.name, "林间精灵")
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self,
                                                 from: JSONEncoder().encode(renamed)), renamed)
    }
    func testLegacyMissingBackendDefaultsToNativeButNullAndUnknownFail() throws {
        let item = MediaItem(url: root.appendingPathComponent("video.mov"), kind: .video, width: 1, height: 1, duration: 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "backend")
        XCTAssertEqual(try decode(json).backend, .native)
        for invalid: Any in [NSNull(), 2, "unknown"] {
            json["backend"] = invalid
            XCTAssertThrowsError(try decode(json))
        }
    }
    func testWebMustUseFixedSecondsAndVersionTwo() throws {
        var value = library(webpage())
        for mode in [TimingMode.full, .loops] {
            value.playlists[0].entries[0].timing.mode = mode
            XCTAssertThrowsError(try value.validate())
        }
        value.playlists[0].entries[0].timing.mode = .seconds
        value.version = 1
        XCTAssertThrowsError(try value.validate())
    }
    func testInvalidBackendAndProjectCombinationsAreRejected() throws {
        let url = root.appendingPathComponent("index.html")
        let project = WebProjectReference(root: root, entry: "index.html")
        for item in [MediaItem(url: url, kind: .web, width: 1, height: 1),
                     MediaItem(url: url, kind: .web, width: 1, height: 1, backend: .web),
                     MediaItem(url: url, kind: .image, width: 1, height: 1, backend: .extended),
                     MediaItem(url: url, kind: .video, width: 1, height: 1, backend: .native, webProject: project)] {
            XCTAssertThrowsError(try library(item).validate())
        }
    }
    func testProjectEntryRejectsTraversalAbsoluteAndNonHTML() {
        for entry in ["../index.html", "/index.html", "a/../index.html", "a//index.html", "", "main.js"] {
            XCTAssertThrowsError(try WebProjectReference(root: root, entry: entry).validate())
        }
        XCTAssertNoThrow(try WebProjectReference(root: root, entry: "子目录/main.htm").validate())
    }
    func testWebBatchAudioAppliesAndInvalidMixedTimingIsAtomic() throws {
        var value = library(webpage())
        let video = MediaItem(url: root.appendingPathComponent("video.mkv"), kind: .video,
                              width: 320, height: 180, duration: 2, backend: .extended)
        value.media.append(video)
        value.playlists[0].entries.append(PlaylistEntry(mediaID: video.id))
        let list = value.playlists[0]
        let selected = Set(list.entries.map(\.id))
        let result = try BatchOperation.editEntries(playlistID: list.id, ids: selected,
            patch: EntryBatchPatch(isMuted: true, volume: 0.3)).applying(to: value)
        XCTAssertTrue(result.playlists[0].entries.allSatisfy { $0.audio == AudioSettings(isMuted: true, volume: 0.3) })
        XCTAssertThrowsError(try BatchOperation.editEntries(playlistID: list.id, ids: selected,
            patch: EntryBatchPatch(timing: EntryTiming(mode: .full))).applying(to: value))
        XCTAssertEqual(value.playlists[0], list)
    }
    private func decode(_ json: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
