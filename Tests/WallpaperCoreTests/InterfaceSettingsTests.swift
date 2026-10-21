import XCTest
@testable import WallpaperCore

final class InterfaceSettingsTests: XCTestCase {
    func testSystemLanguageMatchesRegionalAndScriptVariantsInPreferenceOrder() {
        let cases: [(String, AppLanguage)] = [
            ("zh-Hans-CN", .chinese), ("zh-Hant-TW", .chinese), ("zh_HK", .chinese),
            ("en-GB", .english), ("ja-JP", .japanese), ("fr-CA", .french), ("es-MX", .spanish)
        ]
        for (identifier, expected) in cases {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: [identifier, "en"]), expected)
        }
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["de-DE", "ja-JP", "fr"]), .japanese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["es", "zh-Hans"]), .spanish)
    }

    func testUnsupportedOrEmptySystemLanguagesUseTheDocumentedEnglishDefault() {
        for preferences in [[], ["de-DE", "ko-KR"], [""]] {
            XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: preferences), .english)
        }
    }

    func testExplicitLanguageIgnoresSystemPreferences() {
        for language in AppLanguage.allCases where language != .system {
            XCTAssertEqual(language.resolved(preferredLanguages: ["de", "fr", "en"]), language)
        }
    }

    func testNewAndLegacySettingsFollowSystemThemeAndLanguage() throws {
        for settings in [AppSettings(), try decode(), try decode(appearance: #"{"transparency":0.4,"blur":"clear"}"#)] {
            let encoded = try json(settings)
            XCTAssertEqual(encoded["language"] as? String, "system")
            XCTAssertEqual(encoded["webWallpaperFrameRate"] as? Int, 30)
            XCTAssertEqual((encoded["appearance"] as? [String: Any])?["theme"] as? String, "system")
        }
    }

    func testEveryWebWallpaperFrameRateSurvivesSettingsRoundTrip() throws {
        for rate in [24, 30, 60] {
            let settings = try decode(webWallpaperFrameRate: String(rate))
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(try json(restored)["webWallpaperFrameRate"] as? Int, rate)
        }
    }

    func testInvalidWebWallpaperFrameRateIsReportedInsteadOfDefaulted() {
        for value in ["null", "true", #""30""#, "0", "25", "120", "30.5", "[]", "{}"] {
            XCTAssertThrowsError(try decode(webWallpaperFrameRate: value),
                                 "Invalid webpage frame rate: \(value)")
        }
    }

    func testEveryLanguageSurvivesSettingsRoundTrip() throws {
        for language in ["system", "zh-Hans", "en", "ja", "fr", "es"] {
            let settings = try decode(language: #""\#(language)""#)
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(try json(restored)["language"] as? String, language)
        }
    }

    func testEveryThemeSurvivesSettingsRoundTripWithoutChangingGlassSettings() throws {
        for theme in ["system", "light", "dark"] {
            let settings = try decode(appearance:
                #"{"transparency":0.4,"blur":"clear","fullScreenFrameRate":60,"theme":"\#(theme)"}"#)
            let appearance = try XCTUnwrap(json(settings)["appearance"] as? [String: Any])
            XCTAssertEqual(appearance["theme"] as? String, theme)
            XCTAssertEqual(appearance["transparency"] as? Double, 0.4)
            XCTAssertEqual(appearance["blur"] as? String, "clear")
            XCTAssertEqual(appearance["fullScreenFrameRate"] as? Int, 60)
        }
    }

    func testInvalidLanguageIsReportedInsteadOfSilentlyReset() {
        for value in ["null", "true", "1", #""de""#, #""""#, "[]", "{}"] {
            XCTAssertThrowsError(try decode(language: value), "Invalid language: \(value)")
        }
    }

    func testInvalidThemeIsReportedInsteadOfSilentlyReset() {
        for value in ["null", "false", "1", #""unknown""#, #""""#, "[]", "{}"] {
            XCTAssertThrowsError(try decode(appearance:
                #"{"transparency":0.4,"blur":"clear","theme":\#(value)}"#), "Invalid theme: \(value)")
        }
    }

    private func decode(language: String? = nil, appearance: String? = nil,
                        webWallpaperFrameRate: String? = nil) throws -> AppSettings {
        let languageField = language.map { #", "language":\#($0)"# } ?? ""
        let appearanceField = appearance.map { #", "appearance":\#($0)"# } ?? ""
        let webFrameRateField = webWallpaperFrameRate.map { #", "webWallpaperFrameRate":\#($0)"# } ?? ""
        let source = #"{"pauseOnLowPower":false,"pauseOnHighTemperature":true\#(languageField)\#(appearanceField)\#(webFrameRateField)}"#
        return try JSONDecoder().decode(AppSettings.self, from: Data(source.utf8))
    }

    private func json(_ settings: AppSettings) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
    }
}
