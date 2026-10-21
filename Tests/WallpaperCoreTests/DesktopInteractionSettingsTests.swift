import XCTest
@testable import WallpaperCore

final class DesktopInteractionSettingsTests: XCTestCase {
    func testNewSettingsDisableDesktopInteraction() throws {
        XCTAssertEqual(try encoded(AppSettings())["webInteractionEnabled"] as? Bool, false)
    }

    func testExistingSettingsWithoutInteractionRemainDisabled() throws {
        let settings = try decode(#"{"pauseOnLowPower":false,"pauseOnHighTemperature":true,"isMuted":false}"#)
        XCTAssertEqual(try encoded(settings)["webInteractionEnabled"] as? Bool, false)
    }

    func testEnabledInteractionSurvivesRoundTrip() throws {
        let settings = try decode(#"{"pauseOnLowPower":false,"pauseOnHighTemperature":true,"webInteractionEnabled":true}"#)
        XCTAssertEqual(try encoded(settings)["webInteractionEnabled"] as? Bool, true)
    }

    func testMalformedInteractionSettingIsReported() {
        for value in ["null", "\"true\"", "1"] {
            XCTAssertThrowsError(try decode("{\"pauseOnLowPower\":false,\"pauseOnHighTemperature\":true,\"webInteractionEnabled\":\(value)}"))
        }
    }

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    private func encoded(_ settings: AppSettings) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }
}
