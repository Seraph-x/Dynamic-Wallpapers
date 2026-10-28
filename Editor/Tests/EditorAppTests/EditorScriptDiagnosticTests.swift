import XCTest
@testable import EditorApp

final class EditorScriptDiagnosticTests: XCTestCase {
    private func issue(_ changes: [String: Any] = [:]) -> [String: Any] {
        ["layerId": 1, "layerName": "Layer", "target": "alpha", "phase": "update", "message": "failure", "line": 2, "count": 1].merging(changes) { _, new in new }
    }
    func testExactSchemaPreservesDisplayStringsAndActualCounts() throws {
        let value = try EditorScriptDiagnostic(validated: issue(["layerId": 1.5, "layerName": "", "message": "\0世界😀", "line": NSNull(), "count": 9]))
        XCTAssertEqual(value.layerID, 1.5); XCTAssertEqual(value.layerName, "")
        XCTAssertEqual(value.message, "\0世界😀"); XCTAssertNil(value.line); XCTAssertEqual(value.count, 9)
        for changes: [String: Any] in [["layerId": true], ["line": false], ["count": 0], ["count": 1.5], ["line": 9007199254740992.0], ["extra": 1], ["target": 2]] {
            XCTAssertThrowsError(try EditorScriptDiagnostic(validated: issue(changes)))
        }
        var missing = issue(); missing["line"] = nil
        XCTAssertThrowsError(try EditorScriptDiagnostic(validated: missing))
    }
    func testIssueIdentityDoesNotNormalizeUnicode() throws {
        let composed = try EditorScriptDiagnostic(validated: issue(["message": "é"]))
        let decomposed = try EditorScriptDiagnostic(validated: issue(["message": "e\u{301}"]))
        XCTAssertNotEqual(composed.key, decomposed.key)
    }
    func testExternalResourceSourceIsExactValidatedAndPartOfIdentity() throws {
        let source: [String: Any] = ["kind": "resource", "path": "materials/雪.json", "sha256": String(repeating: "a", count: 64),
                                     "pointer": ["passes", 0, "constantshadervalues", "颜色", "script"], "text": "// 😀\r\nthrow Error('x')"]
        let value = try EditorScriptDiagnostic(validated: issue(["source": source]))
        XCTAssertEqual(value.source?.path, "materials/雪.json")
        XCTAssertEqual(value.source?.pointer, [AnyHashable("passes"), AnyHashable(0), AnyHashable("constantshadervalues"), AnyHashable("颜色"), AnyHashable("script")])
        XCTAssertNotEqual(value.key, try EditorScriptDiagnostic(validated: issue()).key)
        XCTAssertNotEqual(value.key, try EditorScriptDiagnostic(validated: issue(["source": source.merging(["sha256": String(repeating: "b", count: 64)]) { _, new in new }])).key)
        for invalid: [String: Any] in [
            source.merging(["extra": 1]) { _, new in new }, source.merging(["kind": "inline"]) { _, new in new },
            source.merging(["path": "../x"]) { _, new in new }, source.merging(["path": "a//x"]) { _, new in new },
            source.merging(["sha256": String(repeating: "A", count: 64)]) { _, new in new },
            source.merging(["pointer": ["passes", true]]) { _, new in new }
        ] { XCTAssertThrowsError(try EditorScriptDiagnostic(validated: issue(["source": invalid]))) }
    }
    func testCapturedSourceUsesUniqueStructuralAnchorAndPreservesBytesAndLine() throws {
        let source = "// 世界😀\r\nthrow Error('x')\r\n"
        let scene: [String: Any] = ["objects": [["id": 1, "alpha": ["script": source], "effects": [["visible": ["script": "effect"]]]]], "general": ["zoom": ["script": "general"]]]
        let capture = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: scene)
        let resolved = capture.resolve(try EditorScriptDiagnostic(validated: issue(["line": 99])))
        let link = try XCTUnwrap(resolved.link)
        XCTAssertEqual(link.source, source); XCTAssertEqual(link.line, 99)
        XCTAssertEqual(link.dictionary["path"] as? [AnyHashable], ["objects", 0, "alpha", "script"])
        XCTAssertTrue(link.registered); XCTAssertEqual(link.documentIdentity, "capture")
        let effect = capture.resolve(try EditorScriptDiagnostic(validated: issue(["target": "effects[0].visible"])))
        XCTAssertEqual(effect.link?.source, "effect")
        let general = capture.resolve(try EditorScriptDiagnostic(validated: issue(["layerId": NSNull(), "target": "general.zoom"])))
        XCTAssertEqual(general.link?.source, "general"); XCTAssertEqual(general.link?.registered, false)
    }
    func testExternalIssueResolvesItsIndependentCapturedResourceSource() throws {
        let capture = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": []])
        let descriptor: [String: Any] = ["kind": "resource", "path": "materials/雪.json", "sha256": String(repeating: "a", count: 64),
                                               "pointer": ["passes", 0, "constantshadervalues", "颜色", "script"], "text": "// exact\r\nthrow Error('x')"]
        let result = capture.resolve(try EditorScriptDiagnostic(validated: issue(["source": descriptor, "line": 2])))
        let link = try XCTUnwrap(result.link)
        XCTAssertEqual(link.source, "// exact\r\nthrow Error('x')")
        XCTAssertEqual(link.resource?.path, "materials/雪.json")
        let serialized = try XCTUnwrap(link.dictionary["resource"] as? [String: Any])
        XCTAssertEqual(serialized["sha256"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(serialized["pointer"] as? [AnyHashable], ["passes", 0, "constantshadervalues", "颜色", "script"])
    }
    func testCapturedSourceIsDetachedAndUnknownMetadataRemainsReadOnly() throws {
        let wrapper = NSMutableDictionary(dictionary: ["script": "// original\r\n世界😀\n"])
        let layer = NSMutableDictionary(dictionary: ["id": 1, "future": wrapper])
        let capture = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": [layer]])
        wrapper["script"] = "modified"
        let result = capture.resolve(try EditorScriptDiagnostic(validated: issue(["target": "future", "line": NSNull()])))
        XCTAssertEqual(result.link?.source, "// original\r\n世界😀\n")
        XCTAssertEqual(result.link?.registered, false); XCTAssertNil(result.link?.line)
        let colliding = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": [["id": 1, "alpha": ["script": "explicit"]], ["alpha": ["script": "default index 1"]]]])
        XCTAssertNil(colliding.resolve(try EditorScriptDiagnostic(validated: issue())).link)
        let stringID = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": [["id": "1", "alpha": ["script": "string"]]]])
        XCTAssertNil(stringID.resolve(try EditorScriptDiagnostic(validated: issue(["layerId": NSNull()]))).link)
    }
    func testAmbiguousMissingStringAndFractionalIDsNeverGuessAnotherLayer() throws {
        for objects: [[String: Any]] in [
            [["id": 1, "alpha": ["script": "a"]], ["id": 1, "alpha": ["script": "b"]]],
            [["alpha": ["script": "missing"]]], [["id": "1", "alpha": ["script": "string"]]],
            [["id": 1.5, "alpha": ["script": "fraction"]]]
        ] {
            let capture = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": objects])
            let result = capture.resolve(try EditorScriptDiagnostic(validated: issue()))
            XCTAssertNil(result.link); XCTAssertNotNil(result.reasonKey)
        }
        let fraction = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": [["id": 1.5, "alpha": ["script": "fraction"]]]])
        XCTAssertNil(fraction.resolve(try EditorScriptDiagnostic(validated: issue(["layerId": 1.5]))).link)
    }
}
