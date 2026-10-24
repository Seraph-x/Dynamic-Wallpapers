import XCTest
@testable import WallpaperCore

final class AudioSettingsTests: XCTestCase {
    func testSystemAudioSpectrumDefaultsOffAndRoundTrips() throws {
        let data = Data(#"{"pauseOnLowPower":false,"pauseOnHighTemperature":true}"#.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(settings.systemAudioSpectrumEnabled)
        settings.systemAudioSpectrumEnabled = true
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).systemAudioSpectrumEnabled)
        for invalid in ["null", "1", "\"true\""] {
            let value = "{\"pauseOnLowPower\":false,\"pauseOnHighTemperature\":true,\"systemAudioSpectrumEnabled\":\(invalid)}"
            XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: Data(value.utf8)))
        }
    }
    func testLegacySettingsKeepGlobalMute() throws {
        let data = Data(#"{"pauseOnLowPower":false,"pauseOnHighTemperature":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(encoded["isMuted"] as? Bool, true)
    }

    func testGlobalMuteSurvivesRoundTrip() throws {
        let data = Data(#"{"pauseOnLowPower":false,"pauseOnHighTemperature":true,"isMuted":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        XCTAssertEqual(encoded["isMuted"] as? Bool, false)
    }

    func testEntryAudioSurvivesRoundTrip() throws {
        let entry = PlaylistEntry(mediaID: UUID())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json["audio"] = ["isMuted": true, "volume": 0.35]
        let decoded = try JSONDecoder().decode(PlaylistEntry.self, from: JSONSerialization.data(withJSONObject: json))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        let audio = try XCTUnwrap(encoded["audio"] as? [String: Any])
        XCTAssertEqual(audio["isMuted"] as? Bool, true)
        XCTAssertEqual(audio["volume"] as? Double, 0.35)
    }

    func testMalformedGlobalMuteIsRejected() {
        let data = Data(#"{"pauseOnLowPower":false,"pauseOnHighTemperature":true,"isMuted":"false"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: data))
    }
    func testLegacyEntryReceivesAudioDefaults() throws {
        let entry = PlaylistEntry(mediaID: UUID())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "audio")
        let decoded = try JSONDecoder().decode(PlaylistEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.audio, AudioSettings(isMuted: false, volume: 1))
        json["audio"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(PlaylistEntry.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testAudioVolumeValidationRejectsInvalidValues() throws {
        for volume in [-0.01, 1.01, .infinity, .nan] {
            XCTAssertThrowsError(try AudioSettings(volume: volume).validate())
        }
        try AudioSettings(volume: 0).validate()
        try AudioSettings(volume: 1).validate()
    }

}
