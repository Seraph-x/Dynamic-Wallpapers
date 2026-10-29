import Foundation
import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

final class SystemMediaSceneSnapshotTests: XCTestCase {
    private func item(state: SystemMediaPlaybackState = .playing) throws -> SystemMediaSnapshot {
        try SystemMediaSnapshot(source: .music, trackID: "owned-0", state: state,
            title: "真实标题 🎵\n<script>", artist: "作者", album: "Album", albumArtist: nil,
            position: 12.75, duration: 180.5)
    }

    private func object(_ value: SystemMediaSceneSnapshot) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSDictionary)
    }

    func testProjectionPreservesActualUnicodeMetadataAndTimeline() throws {
        let native = try item()
        let value = SystemMediaSceneSnapshot(snapshot: native, artwork: .unavailable)
        let json = try object(value)
        XCTAssertEqual(Set(json.allKeys.compactMap { $0 as? String }),
            ["hasMedia", "state", "title", "artist", "album", "albumArtist", "position", "duration", "thumbnail"])
        XCTAssertEqual(json["hasMedia"] as? Bool, true)
        XCTAssertEqual(json["title"] as? String, native.title)
        XCTAssertEqual(json["artist"] as? String, native.artist)
        XCTAssertEqual(json["album"] as? String, native.album)
        XCTAssertEqual(json["albumArtist"] as? String, "")
        XCTAssertEqual(json["position"] as? Double, 12.75)
        XCTAssertEqual(json["duration"] as? Double, 180.5)
        XCTAssertTrue(json["thumbnail"] is NSNull)
    }

    func testProjectionUsesDocumentedCoarsePlaybackStates() throws {
        for (state, expected) in [(SystemMediaPlaybackState.stopped, 0), (.paused, 2),
                                  (.playing, 1), (.fastForwarding, 1), (.rewinding, 1)] {
            XCTAssertEqual(try object(SystemMediaSceneSnapshot(snapshot: item(state: state), artwork: .unavailable))["state"] as? Int, expected)
        }
    }

    func testMatchingDecodedArtworkCarriesItsExactActualPNGBytes() throws {
        let native = try item()
        let bytes = try Data(contentsOf: ArtworkImageDecoderTests.fixtureURL)
        let artwork = try ArtworkImageDecoder.decode(bytes, for: SystemMediaArtworkIdentity(native))
        let value = SystemMediaSceneSnapshot(snapshot: native, artwork: .ready(artwork))
        XCTAssertEqual(try object(value)["thumbnail"] as? String,
                       "data:image/png;base64," + artwork.pngData.base64EncodedString())
    }

    func testMissingPendingFailedAndStaleArtworkDoNotReplaceValidMetadata() throws {
        let native = try item()
        let identity = SystemMediaArtworkIdentity(native)
        let bytes = try Data(contentsOf: ArtworkImageDecoderTests.fixtureURL)
        for stale in [SystemMediaArtworkIdentity(source: .spotify, trackID: identity.trackID),
                      SystemMediaArtworkIdentity(source: .music, trackID: "other")] {
            let artwork = try ArtworkImageDecoder.decode(bytes, for: stale)
            let json = try object(SystemMediaSceneSnapshot(snapshot: native, artwork: .ready(artwork)))
            XCTAssertTrue(json["thumbnail"] is NSNull)
            XCTAssertEqual(json["title"] as? String, native.title)
        }
        for state in [SystemMediaArtworkState.unavailable, .pending(identity),
                      .failed(identity, SystemMediaArtworkError.httpStatus(503))] {
            let json = try object(SystemMediaSceneSnapshot(snapshot: native, artwork: state))
            XCTAssertTrue(json["thumbnail"] is NSNull)
            XCTAssertEqual(json["hasMedia"] as? Bool, true)
            XCTAssertEqual(json["title"] as? String, native.title)
        }
    }

    func testEmptySnapshotClearsAllFieldsEvenIfOldArtworkIsReady() throws {
        let native = try item()
        let artwork = try ArtworkImageDecoder.decode(Data(contentsOf: ArtworkImageDecoderTests.fixtureURL),
                                                     for: SystemMediaArtworkIdentity(native))
        let empty = try object(SystemMediaSceneSnapshot(snapshot: nil, artwork: .ready(artwork)))
        XCTAssertEqual(empty, ["hasMedia": false, "state": 0, "title": "", "artist": "", "album": "",
                              "albumArtist": "", "position": 0, "duration": 0, "thumbnail": NSNull()] as NSDictionary)
    }
}
