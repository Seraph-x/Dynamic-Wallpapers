import XCTest
import WallpaperCore
import ScreenSaverCore

final class ManifestTests: XCTestCase {
    func testManifestRoundTripContainsOnlyIndependentNativeMetadata() throws {
        let fixture = try StorageFixture()
        let manifest = try fixture.manifest(id: UUID())
        let bytes = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(ScreenSaverManifest.self, from: bytes), manifest)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.entries, fixture.projection.entries)
        XCTAssertEqual(manifest.files, [fixture.file])
        XCTAssertTrue(manifest.isMuted)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("source-only"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("bookmark"))
    }

    func testInvalidVersionIdentityReferencesAndNumbersAreRejected() throws {
        let fixture = try StorageFixture()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.manifest(id: UUID()))) as? [String: Any])
        let file = try XCTUnwrap((original["files"] as? [[String: Any]])?.first)
        let entry = try XCTUnwrap((original["entries"] as? [[String: Any]])?.first)
        let mutations: [[String: Any]] = [
            ["schemaVersion": 2], ["generationID": "bad"], ["transition": -1],
            ["files": [file, file]], ["entries": [entry, entry]], ["entries": []], ["files": []],
            ["entries": [entry.merging(["mediaID": UUID().uuidString]) { _, new in new }]],
            ["files": [file.merging(["backend": "extended"]) { _, new in new }]],
            ["files": [file.merging(["byteCount": 0]) { _, new in new }]],
            ["files": [file.merging(["sha256": "bad"]) { _, new in new }]],
            ["files": [file.merging(["width": 0]) { _, new in new }]],
            ["files": [file.merging(["kind": "video"]) { _, new in new }]]
        ]
        for change in mutations {
            XCTAssertThrowsError(try JSONDecoder().decode(ScreenSaverManifest.self,
                from: JSONSerialization.data(withJSONObject: original.merging(change) { _, new in new })))
        }
    }

    func testAbsoluteTraversalReservedAndNonCanonicalMediaPathsFail() throws {
        let fixture = try StorageFixture()
        let manifest = try fixture.manifest(id: UUID())
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        let file = try XCTUnwrap((original["files"] as? [[String: Any]])?.first)
        for path in ["/tmp/a.png", "../a.png", "media/../a.png", "media//a.png", "media/./a.png", "media/", ".lease", "manifest.json", "media/a\0.png"] {
            var json = original
            json["files"] = [file.merging(["relativePath": path]) { _, new in new }]
            XCTAssertThrowsError(try JSONDecoder().decode(ScreenSaverManifest.self, from: JSONSerialization.data(withJSONObject: json)), path)
        }
    }

    func testPointerRejectsUnknownFormatAndHalfConfiguredState() throws {
        let fixture = try StorageFixture()
        let manifest = try fixture.manifest(id: UUID())
        let active = ScreenSaverCurrentPointer(exportID: UUID(), generationID: manifest.generationID,
            sourceRevision: manifest.sourceRevision, settingsRevision: UUID())
        let bytes = try JSONEncoder().encode(active)
        XCTAssertEqual(try JSONDecoder().decode(ScreenSaverCurrentPointer.self, from: bytes), active)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for change: [String: Any] in [["schemaVersion": 99], ["generationID": NSNull()], ["sourceRevision": NSNull()], ["exportID": "invalid"]] {
            XCTAssertThrowsError(try JSONDecoder().decode(ScreenSaverCurrentPointer.self,
                from: JSONSerialization.data(withJSONObject: original.merging(change) { _, new in new })))
        }
        let disabled = ScreenSaverCurrentPointer(exportID: active.exportID, generationID: nil, sourceRevision: nil,
                                                settingsRevision: UUID())
        try disabled.validate()
    }
}
