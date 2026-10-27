import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

final class SystemMediaSnapshotTests: XCTestCase {
    func testSnapshotPreservesUnicodeAndPausedTrack() throws {
        let value = try SystemMediaSnapshot(source: .music, trackID: "AA12", state: .paused,
            title: "雪\n\"é🎵", artist: "演奏者", album: "Álbum", albumArtist: "合奏", position: 12.25, duration: 120)
        XCTAssertEqual(value.title, "雪\n\"é🎵")
        XCTAssertEqual(value.state.wallpaperPlaybackState, 2)
        XCTAssertEqual(value.position, 12.25)
    }

    func testInvalidSnapshotValuesFailInsteadOfClampingOrFabricating() {
        for (source, id, position, duration) in [
            (SystemMediaSource.disabled, "id", 0.0, 1.0), (.music, "", 0, 1),
            (.spotify, "id", Double.nan, 1), (.music, "id", -1, 1),
            (.music, "id", 0, Double.infinity), (.spotify, "id", 0, -1)
        ] {
            XCTAssertThrowsError(try SystemMediaSnapshot(source: source, trackID: id, state: .playing,
                title: "", artist: "", album: "", albumArtist: nil, position: position, duration: duration))
        }
    }

    func testSeekingStatesRemainExplicitAndMapToPlayingForWallpaperEvents() {
        XCTAssertEqual(SystemMediaPlaybackState.fastForwarding.wallpaperPlaybackState, 1)
        XCTAssertEqual(SystemMediaPlaybackState.rewinding.wallpaperPlaybackState, 1)
        XCTAssertEqual(SystemMediaPlaybackState.stopped.wallpaperPlaybackState, 0)
    }
}
