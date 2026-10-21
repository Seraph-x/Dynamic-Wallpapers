import Foundation
import XCTest
@testable import WallpaperCore

final class StartupSettingsTests: XCTestCase {
    func testDefaultSettingsEncodeVisibleDockIcon() throws {
        XCTAssertEqual(try encoded(AppSettings())["showDockIcon"] as? Bool, true)
    }

    func testOlderSettingsKeepDockIconVisible() throws {
        var json = try encoded(AppSettings())
        json.removeValue(forKey: "showDockIcon")
        let restored = try decode(json)
        XCTAssertEqual(try encoded(restored)["showDockIcon"] as? Bool, true)
    }

    func testHiddenDockIconSurvivesSettingsRoundTrip() throws {
        var json = try encoded(AppSettings())
        json["showDockIcon"] = false
        let restored = try decode(json)
        XCTAssertEqual(try encoded(restored)["showDockIcon"] as? Bool, false)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(restored)), restored)
    }

    func testMalformedDockChoiceIsNotReplacedWithADefault() throws {
        for malformed: Any in [NSNull(), "false", 0, [false]] {
            var json = try encoded(AppSettings())
            json["showDockIcon"] = malformed
            XCTAssertThrowsError(try decode(json), "Invalid Dock setting: \(malformed)")
        }
    }

    func testOtherAppFullScreenSettingDefaultsOffAndRoundTrips() throws {
        var json = try encoded(AppSettings())
        json.removeValue(forKey: "pauseOnOtherAppFullScreen")
        XCTAssertFalse(try decode(json).pauseOnOtherAppFullScreen)
        json["pauseOnOtherAppFullScreen"] = true
        XCTAssertTrue(try decode(json).pauseOnOtherAppFullScreen)
        XCTAssertEqual(try decode(encoded(try decode(json))), try decode(json))
        json["pauseOnOtherAppFullScreen"] = "true"
        XCTAssertThrowsError(try decode(json))
    }

    private func encoded(_ settings: AppSettings) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }

    private func decode(_ json: [String: Any]) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
