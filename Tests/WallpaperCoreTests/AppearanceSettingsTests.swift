import XCTest
@testable import WallpaperCore

final class AppearanceSettingsTests: XCTestCase {
    func testOlderSettingsReceiveTheExistingFrostedAppearance() throws {
        let appearance = try encodedAppearance(decode())
        XCTAssertEqual(appearance["transparency"] as? Double, 0.75)
        XCTAssertEqual(appearance["blur"] as? String, "frosted")
        XCTAssertEqual(appearance["accentColor"] as? String, "#BFE2FF")
    }

    func testAppearanceSurvivesSettingsRoundTrip() throws {
        for transparency in [0.45, 1.0] {
            for blur in ["clear", "frosted"] {
                let settings = try decode(appearance: #"{"transparency":\#(transparency),"blur":"\#(blur)"}"#)
                let appearance = try encodedAppearance(settings)
                XCTAssertEqual(appearance["transparency"] as? Double, transparency)
                XCTAssertEqual(appearance["blur"] as? String, blur)
            }
        }
    }

    func testLegacyAppearanceDefaultsToThirtyHertz() throws {
        for settings in [try decode(), try decode(appearance: #"{"transparency":0.45,"blur":"clear"}"#)] {
            XCTAssertEqual(try encodedAppearance(settings)["fullScreenFrameRate"] as? Int, 30)
        }
    }

    func testBothFullscreenFrameRatesSurviveSettingsRoundTrip() throws {
        for rate in [30, 60] {
            let settings = try decode(appearance:
                #"{"transparency":0.45,"blur":"clear","fullScreenFrameRate":\#(rate)}"#)
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(try encodedAppearance(restored)["fullScreenFrameRate"] as? Int, rate)
        }
    }

    func testAccentColorParsesUserCodesAndUsesOneCanonicalRepresentation() throws {
        XCTAssertEqual(try AppAccentColor(hexCode: "#12abEF").hexCode, "#12ABEF")
        XCTAssertEqual(try AppAccentColor(hexCode: " 12abef ").hexCode, "#12ABEF")
        XCTAssertEqual(try AppAccentColor(hexCode: "#12ABEF"),
                       AppAccentColor(red: 0x12, green: 0xAB, blue: 0xEF))
        for invalid in ["", "#FFF", "#1234567", "#GG0000", "12345G", "#123456FF"] {
            XCTAssertThrowsError(try AppAccentColor(hexCode: invalid), "Invalid accent code: \(invalid)")
        }
    }

    func testAccentColorSurvivesSettingsRoundTrip() throws {
        let settings = try decode(appearance:
            ##"{"transparency":0.45,"blur":"clear","accentColor":"#12abEF"}"##)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.appearance.accentColor.hexCode, "#12ABEF")
        XCTAssertEqual(try encodedAppearance(restored)["accentColor"] as? String, "#12ABEF")
    }

    func testPresentInvalidAccentColorIsNotDefaulted() {
        for value in ["null", "true", "1", "\"#FFF\"", "\"#GG0000\"", "[]", "{}"] {
            XCTAssertThrowsError(try decode(appearance:
                #"{"transparency":0.45,"blur":"clear","accentColor":\#(value)}"#),
                "Invalid accent color must remain visible: \(value)")
        }
    }

    func testPresentButInvalidFullscreenFrameRateIsNotDefaulted() {
        for rate in ["null", "true", #""60""#, "0", "45", "120", "30.5"] {
            XCTAssertThrowsError(try decode(appearance:
                #"{"transparency":0.45,"blur":"clear","fullScreenFrameRate":\#(rate)}"#),
                "Invalid full screen frame rate must remain visible: \(rate)")
        }
    }

    func testMalformedAppearanceIsReportedInsteadOfResetToDefaults() {
        for value in ["null", "true", "{}", #"{"transparency":"0.5","blur":"clear"}"#,
                      #"{"transparency":0.5,"blur":"unknown"}"#,
                      #"{"transparency":null,"blur":"clear"}"#,
                      #"{"transparency":-0.01,"blur":"clear"}"#,
                      #"{"transparency":1.01,"blur":"frosted"}"#] {
            XCTAssertThrowsError(try decode(appearance: value), "Invalid appearance: \(value)")
        }
    }

    private func decode(appearance: String? = nil) throws -> AppSettings {
        let field = appearance.map { #", "appearance":\#($0)"# } ?? ""
        let json = #"{"pauseOnLowPower":false,"pauseOnHighTemperature":true\#(field)}"#
        return try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    private func encodedAppearance(_ settings: AppSettings) throws -> [String: Any] {
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        return try XCTUnwrap(encoded["appearance"] as? [String: Any])
    }
}
