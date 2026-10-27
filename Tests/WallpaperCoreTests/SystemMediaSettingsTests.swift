import XCTest
@testable import WallpaperCore

final class SystemMediaSettingsTests: XCTestCase {
    func testNewAndLegacyLibrariesDisableMediaAutomation() throws {
        XCTAssertEqual(AppSettings().systemMediaSource, .disabled)
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(
            #"{"pauseOnLowPower":true,"pauseOnHighTemperature":true}"#.utf8))
        XCTAssertEqual(settings.systemMediaSource, .disabled)
    }

    func testEachExplicitSourceRoundTrips() throws {
        for source in SystemMediaSource.allCases {
            var settings = AppSettings(); settings.systemMediaSource = source
            let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(restored.systemMediaSource, source)
        }
    }

    func testMalformedOrUnsupportedSourceDoesNotSilentlyReset() {
        for raw in ["null", "false", "3", #""global""#, #""""#, "[]", "{}"] {
            let json = #"{"pauseOnLowPower":true,"pauseOnHighTemperature":true,"systemMediaSource":\#(raw)}"#
            XCTAssertThrowsError(try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)))
        }
    }
}
