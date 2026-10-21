import XCTest
import Darwin
import WallpaperCore
import ScreenSaverCore

final class SettingsTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("screensaver-settings-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testDefaultsAndMissingFileMeanUnconfiguredWithoutWritingAnything() throws {
        let settings = ScreenSaverSettings()
        XCTAssertEqual(settings.schemaVersion, 1)
        XCTAssertNil(settings.source)
        XCTAssertNil(settings.consent)
        XCTAssertTrue(settings.isMuted)
        XCTAssertEqual(settings.fit, .fill)
        let url = directory.appendingPathComponent("screensaver-settings.json")
        XCTAssertNil(try ScreenSaverSettings.read(from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testIndependentSettingsRoundTripKeepsPlaybackOverridesAndConsent() throws {
        let fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let settings = ScreenSaverSettings(source: projection.source, isMuted: false, fit: .fit,
                                           consent: ScreenSaverConsent(acknowledging: projection))
        let url = directory.appendingPathComponent("screensaver-settings.json")
        try JSONEncoder().encode(settings).write(to: url)
        XCTAssertEqual(try ScreenSaverSettings.read(from: url), settings)
        XCTAssertEqual(settings.selecting(.media(fixture.image.id)).fit, .fit)
        XCTAssertFalse(settings.selecting(nil).isMuted)
    }

    func testCorruptUnknownVersionAndMissingRequiredSettingsAreRejectedUntouched() throws {
        let encoder = JSONEncoder()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(ScreenSaverSettings())) as? [String: Any])
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schemaVersion"] = 2 }, { $0["schemaVersion"] = 0 },
            { $0.removeValue(forKey: "schemaVersion") }, { $0.removeValue(forKey: "isMuted") },
            { $0["isMuted"] = "true" }, { $0["fit"] = "stretch" },
            { $0["source"] = ["kind": "unknown", "id": UUID().uuidString] }
        ]
        let url = directory.appendingPathComponent("screensaver-settings.json")
        var cases = [Data("{broken".utf8)]
        for mutation in mutations {
            var json = original
            mutation(&json)
            cases.append(try JSONSerialization.data(withJSONObject: json))
        }
        for bytes in cases {
            try bytes.write(to: url)
            XCTAssertThrowsError(try ScreenSaverSettings.read(from: url))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testNonRegularSettingsAndRemotePathsAreErrorsNotMissingConfiguration() throws {
        XCTAssertThrowsError(try ScreenSaverSettings.read(from: directory))
        let dangling = directory.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("missing.json"))
        XCTAssertThrowsError(try ScreenSaverSettings.read(from: dangling))
        XCTAssertThrowsError(try ScreenSaverSettings.read(from: URL(string: "https://invalid.test/settings.json")!))
    }

    func testMalformedConsentIsRejectedDuringSettingsDecode() throws {
        let fixture = ProjectionFixture()
        let projection = try ScreenSaverProjection(library: fixture.library, source: .playlist(fixture.list.id))
        let settings = ScreenSaverSettings(source: projection.source, consent: ScreenSaverConsent(acknowledging: projection))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var wrongSource = original
        wrongSource["source"] = ["kind": "media", "id": fixture.image.id.uuidString]
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenSaverSettings.self,
            from: JSONSerialization.data(withJSONObject: wrongSource)))
        var duplicate = original
        var consent = try XCTUnwrap(duplicate["consent"] as? [String: Any])
        var signatures = try XCTUnwrap(consent["signatures"] as? [[String: Any]])
        signatures.append(signatures[0])
        consent["signatures"] = signatures
        duplicate["consent"] = consent
        XCTAssertThrowsError(try JSONDecoder().decode(ScreenSaverSettings.self,
            from: JSONSerialization.data(withJSONObject: duplicate)))
    }

    func testFIFOIsRejectedWithoutWaitingForAWriter() throws {
        let url = directory.appendingPathComponent("settings.pipe")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertThrowsError(try ScreenSaverSettings.read(from: url))
    }
}
