import XCTest
@testable import WallpaperCore

final class SystemWallpaperSettingsTests: XCTestCase {
    func testNewAndLegacySettingsDisableSystemWallpaperSync() throws {
        let legacy = Data(#"{"pauseOnLowPower":false,"pauseOnHighTemperature":true}"#.utf8)
        for settings in [AppSettings(), try JSONDecoder().decode(AppSettings.self, from: legacy)] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            XCTAssertEqual(json["systemWallpaperSyncEnabled"] as? Bool, false)
        }
    }

    func testExplicitSettingSurvivesRoundTrip() throws {
        for enabled in [true, false] {
            let data = Data("{\"pauseOnLowPower\":false,\"pauseOnHighTemperature\":true,\"systemWallpaperSyncEnabled\":\(enabled)}".utf8)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            XCTAssertEqual(json["systemWallpaperSyncEnabled"] as? Bool, enabled)
        }
    }

    func testInvalidSettingCannotSilentlyDisableSync() {
        for value in ["null", "1", "\"true\"", "[]", "{}"] {
            let data = Data("{\"pauseOnLowPower\":false,\"pauseOnHighTemperature\":true,\"systemWallpaperSyncEnabled\":\(value)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: data), value)
        }
    }
}
