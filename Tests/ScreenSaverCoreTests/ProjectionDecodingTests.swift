import XCTest
import WallpaperCore
import ScreenSaverCore

final class ProjectionDecodingTests: XCTestCase {
    func testDecodedProjectionRejectsBadReferencesNonNativeMediaAndInvalidPlaybackValues() throws {
        let fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any])
        let entries = try XCTUnwrap(original["entries"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        let media = try XCTUnwrap(original["media"] as? [[String: Any]])
        var badReference = entry
        badReference["mediaID"] = UUID().uuidString
        var badAudio = entry
        badAudio["audio"] = ["isMuted": false, "volume": 1.5]
        var badTiming = entry
        badTiming["timing"] = ["mode": "seconds", "seconds": "NaN", "loops": 1]
        var referenceEntries = entries; referenceEntries[0] = badReference
        var audioEntries = entries; audioEntries[0] = badAudio
        var timingEntries = entries; timingEntries[0] = badTiming
        var nonNative = media
        nonNative[0]["kind"] = "video"
        nonNative[0]["backend"] = "extended"
        nonNative[0]["duration"] = 3
        var badBackend = media
        badBackend[0]["backend"] = "unknown"
        var badDuration = media
        badDuration[1]["duration"] = "Infinity"
        let changes: [[String: Any]] = [
            ["entries": referenceEntries], ["entries": entries + [entry]],
            ["entries": audioEntries], ["entries": timingEntries],
            ["media": nonNative], ["media": badBackend], ["media": badDuration], ["transition": "Infinity"]
        ]
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for change in changes {
            let json = original.merging(change) { _, value in value }
            XCTAssertThrowsError(try decoder.decode(ScreenSaverProjection.self, from: JSONSerialization.data(withJSONObject: json)))
        }
    }
}
