import Foundation
import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

final class MediaSnapshotDecoderTests: XCTestCase {
    func testSpotifyMillisecondsAndOptionalAlbumArtist() throws {
        let result = try MediaSnapshotDecoder.decode(source: .spotify, values: values(source: .spotify))
        XCTAssertEqual(result.duration, 180.25)
        XCTAssertEqual(result.position, 12.5)
        XCTAssertNil(result.albumArtist)
        XCTAssertEqual(result.state, .paused)
        XCTAssertEqual(result.trackID, "spotify:track:one")
    }

    func testMusicSecondsAndExplicitSeekingState() throws {
        var data = values(source: .music)
        data[MediaAE.playerState] = NSAppleEventDescriptor(enumCode: MediaAE.code("kPSR"))
        let result = try MediaSnapshotDecoder.decode(source: .music, values: data)
        XCTAssertEqual(result.duration, 180.25)
        XCTAssertEqual(result.albumArtist, "合奏")
        XCTAssertEqual(result.state, .rewinding)
    }

    func testMalformedOrMissingDescriptorsAreErrors() {
        for key in values(source: .music).keys {
            var data = values(source: .music); data.removeValue(forKey: key)
            XCTAssertThrowsError(try MediaSnapshotDecoder.decode(source: .music, values: data))
            data = values(source: .music); data[key] = NSAppleEventDescriptor(boolean: true)
            XCTAssertThrowsError(try MediaSnapshotDecoder.decode(source: .music, values: data))
        }
    }

    func testUnknownPlaybackStateAndNegativeTimelineFail() {
        var data = values(source: .music)
        data[MediaAE.playerState] = NSAppleEventDescriptor(enumCode: MediaAE.code("oops"))
        XCTAssertThrowsError(try MediaSnapshotDecoder.decode(source: .music, values: data))
        data = values(source: .spotify)
        data[MediaAE.duration] = NSAppleEventDescriptor(double: -1)
        XCTAssertThrowsError(try MediaSnapshotDecoder.decode(source: .spotify, values: data))
    }

    private func values(source: SystemMediaSource) -> [OSType: NSAppleEventDescriptor] {
        var result: [OSType: NSAppleEventDescriptor] = [
            MediaAE.playerState: NSAppleEventDescriptor(enumCode: MediaAE.code("kPSp")),
            MediaAE.position: NSAppleEventDescriptor(double: 12.5),
            MediaAE.name: NSAppleEventDescriptor(string: "雪\n\"é🎵"),
            MediaAE.artist: NSAppleEventDescriptor(string: "演奏者"),
            MediaAE.album: NSAppleEventDescriptor(string: "Álbum"),
            MediaAE.duration: NSAppleEventDescriptor(double: source == .spotify ? 180_250 : 180.25),
            MediaAE.identity(for: source): NSAppleEventDescriptor(string: source == .spotify ? "spotify:track:one" : "AA12"),
        ]
        if source == .music { result[MediaAE.albumArtist] = NSAppleEventDescriptor(string: "合奏") }
        return result
    }
}
