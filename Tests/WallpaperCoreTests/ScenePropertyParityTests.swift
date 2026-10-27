import Foundation
import XCTest
@testable import WallpaperCore

final class ScenePropertyParityTests: XCTestCase {
    private struct Row: Encodable {
        let name: String, label: String
        let kind: String?, defaultValue: ScenePropertyValue?
        let minimum: Double?, maximum: Double?, step: Double?, order: Double?
        let options: [Choice]
        let readOnlyReason: String?
        struct Choice: Encodable { let label: String, value: String }
        init(_ value: ScenePropertyDefinition) {
            name = value.name; label = value.label; kind = value.kind?.rawValue; defaultValue = value.defaultValue
            minimum = value.minimum; maximum = value.maximum; step = value.step; order = value.order
            options = value.options.map { Choice(label: $0.label, value: $0.value) }; readOnlyReason = value.readOnlyReason?.rawValue
        }
    }
    private struct Result: Encodable { let id: String, failed: Bool, rows: [Row] }

    func testSharedJavaScriptCatalogFixturesAndOptionalParityArtifact() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/ScenePropertyCatalog/cases.json"))
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [NSDictionary])
        let results = try fixtures.map { fixture -> Result in
            let id = try XCTUnwrap(fixture.object(forKey: "id") as? String)
            let file = try XCTUnwrap(fixture.object(forKey: "file") as? String)
            let bytes = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/ScenePropertyCatalog/" + file))
            do { return Result(id: id, failed: false, rows: try ScenePropertyCatalog(projectJSON: bytes).rows.map(Row.init)) }
            catch { return Result(id: id, failed: true, rows: []) }
        }
        XCTAssertEqual(results.filter(\.failed).map(\.id), ["array", "invalid-general", "invalid-preset"])
        if let destination = ProcessInfo.processInfo.environment["SCENE_PROPERTY_CATALOG_PARITY_OUTPUT"] {
            try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
    }
}
