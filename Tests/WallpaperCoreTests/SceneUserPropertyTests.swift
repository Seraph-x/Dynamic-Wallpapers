import Foundation
import XCTest
@testable import WallpaperCore

final class SceneUserPropertyTests: XCTestCase {
    private var metadata: Data!
    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        metadata = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/ScenePropertyCatalog/project.json"))
    }

    func testExactNamesAndJavaScriptOrderSurviveCatalogAndWire() throws {
        let catalog = try ScenePropertyCatalog(projectJSON: metadata)
        XCTAssertEqual(catalog.rows.count, 14)
        let names = catalog.rows.map { Data($0.name.utf8) }
        XCTAssertEqual(Array(names.prefix(5)), ["enabled", "amount", "tint", "caption", "mode"].map { Data($0.utf8) })
        XCTAssertTrue(names.contains(Data("é".utf8)))
        XCTAssertTrue(names.contains(Data("e\u{301}".utf8)))
        XCTAssertLessThan(names.firstIndex(of: Data("😀".utf8))!, names.firstIndex(of: Data("\u{E000}".utf8))!)
        let values = [ScenePropertyOverride(name: "é", value: .string("one")),
                      ScenePropertyOverride(name: "e\u{301}", value: .string("two"))]
        let wire = try catalog.wireJSON(overrides: values)
        let object = try JSONSerialization.jsonObject(with: wire) as! NSDictionary
        XCTAssertEqual(object.count, 2)
        XCTAssertEqual(object.object(forKey: "é" as NSString) as? String, "one")
        XCTAssertEqual(object.object(forKey: "e\u{301}" as NSString) as? String, "two")
        XCTAssertEqual(catalog.projectJSON, metadata)
    }

    func testReadOnlyDeclarationsRemainVisibleWithReasons() throws {
        let catalog = try ScenePropertyCatalog(projectJSON: metadata)
        for (name, reason) in [("future", "unsupported-type"), ("__proto__", "unsupported-name"),
                               ("conditional", "unsupported-condition"), ("invalid", "invalid-declaration"),
                               ("presetOnly", "preset-only")] {
            let row = try XCTUnwrap(catalog.rows.first { $0.name == name })
            XCTAssertEqual(row.readOnlyReason?.rawValue, reason)
            XCTAssertThrowsError(try catalog.wireJSON(overrides: [.init(name: name, value: .string("invalid"))]))
        }
    }

    func testExactDuplicateDeclarationsKeepRendererLastMemberSemantics() throws {
        let bytes = Data(#"{"general":{"properties":{"x":{"type":"bool","value":false},"x":{"type":"bool","value":true}}}}"#.utf8)
        let catalog = try ScenePropertyCatalog(projectJSON: bytes)
        XCTAssertEqual(catalog.rows.count, 1)
        XCTAssertEqual(catalog.rows.first?.defaultValue, .boolean(true))
        XCTAssertEqual(catalog.projectJSON, bytes)
    }

    func testNestedDuplicateAncestorsAndEscapedNamesKeepLastMember() throws {
        let bytes = Data(#"{"general":{"properties":{"old":{"type":"bool","value":true}}},"general":{"properties":{"x":{"type":"bool","value":true}},"properties":{"\u0078":{"type":"textinput","value":"A\\B\"雪"}}}}"#.utf8)
        let catalog = try ScenePropertyCatalog(projectJSON: bytes)
        XCTAssertEqual(catalog.rows.map(\.name), ["x"])
        XCTAssertEqual(catalog.rows.first?.defaultValue, .string("A\\B\"雪"))
    }

    func testDeepUnknownMetadataAndOverflowNumbersDoNotInvalidateKnownProperties() throws {
        let depth = 12000
        let bytes = Data(("{\"future\":" + String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth) + ",\"general\":{\"properties\":{\"finite\":{\"type\":\"bool\",\"value\":true},\"overflow\":{\"type\":\"slider\",\"value\":1e400}}}}").utf8)
        let catalog = try ScenePropertyCatalog(projectJSON: bytes)
        XCTAssertEqual(catalog.rows.count, 2)
        XCTAssertEqual(catalog.rows.first { $0.name == "finite" }?.defaultValue, .boolean(true))
        XCTAssertEqual(catalog.rows.first { $0.name == "overflow" }?.readOnlyReason, .invalidDeclaration)
        XCTAssertEqual(catalog.projectJSON, bytes)
    }

    func testMetadataParserRejectsMalformedTokensWithoutAcceptingPartialCatalog() throws {
        for json in [#"{"x":01}"#, #"{"x":+1}"#, #"{"x":.5}"#, #"{"x":1.}"#, #"{"x":1e}"#,
                     #"{"x":truefalse}"#, #"{"x":undefined}"#, #"{"x":[1,]}"#, #"{"x":1,}"#,
                     #"{"x":"\uD800"}"#, #"{"x":"\q"}"#, #"{"x":1}{}"#] {
            XCTAssertThrowsError(try ScenePropertyCatalog(projectJSON: Data(json.utf8)), json)
        }
    }

    func testStrictTypesRangesAndCompleteDefaults() throws {
        let catalog = try ScenePropertyCatalog(projectJSON: metadata)
        let values: [ScenePropertyOverride] = [.init(name: "enabled", value: .boolean(true)),
            .init(name: "amount", value: .number(0.8)), .init(name: "tint", value: .string(".5 +1 0e0")),
            .init(name: "caption", value: .string("Live 雪 😀")), .init(name: "mode", value: .string("night"))]
        XCTAssertNoThrow(try catalog.wireJSON(overrides: values))
        let defaults = try catalog.resolvedValues(overrides: [])
        XCTAssertEqual(defaults.count, 9)
        XCTAssertEqual(defaults.first { $0.name == "caption" }?.value, .string("Authored 雪"))
        let resolved = try catalog.resolvedValues(overrides: values)
        XCTAssertEqual(resolved.first { $0.name == "mode" }?.value, .string("night"))
        for value in [ScenePropertyOverride(name: "enabled", value: .number(1)),
                      .init(name: "amount", value: .number(1.1)), .init(name: "amount", value: .number(.nan)),
                      .init(name: "tint", value: .string("1 0")), .init(name: "tint", value: .string("2 0 0")),
                      .init(name: "caption", value: .boolean(false)), .init(name: "mode", value: .string("other")),
                      .init(name: "missing", value: .string("no"))] {
            XCTAssertThrowsError(try catalog.wireJSON(overrides: [value]))
        }
        XCTAssertThrowsError(try catalog.wireJSON(overrides: [values[0], values[0]]))
    }

    func testStringValueIdentityAndChoiceMembershipUseExactBytes() throws {
        XCTAssertNotEqual(ScenePropertyValue.string("é"), ScenePropertyValue.string("e\u{301}"))
        XCTAssertNotEqual(ScenePropertyOverride(name: "é", value: .boolean(true)),
                          ScenePropertyOverride(name: "e\u{301}", value: .boolean(true)))
        let catalog = try ScenePropertyCatalog(projectJSON: Data(#"{"general":{"properties":{"choice":{"type":"combo","value":"é","options":[{"label":"One","value":"é"}]}}}}"#.utf8))
        XCTAssertThrowsError(try catalog.wireJSON(overrides: [.init(name: "choice", value: .string("e\u{301}"))]))
    }

    func testDefinitionAndChoiceEqualityRetainExactAuthoredStrings() throws {
        let source = Data(#"{"general":{"properties":{"é":{"type":"bool","value":true},"e\u0301":{"type":"bool","value":true},"choice":{"type":"combo","value":"é","options":[{"label":"é","value":"é"},{"label":"e\u0301","value":"e\u0301"}]}}}}"#.utf8)
        let catalog = try ScenePropertyCatalog(projectJSON: source)
        let bools = catalog.rows.filter { $0.kind == .bool }
        XCTAssertEqual(bools.count, 2)
        XCTAssertNotEqual(bools[0], bools[1])
        let options = try XCTUnwrap(catalog.rows.first { $0.name == "choice" }).options
        XCTAssertNotEqual(options[0], options[1])
    }

    func testMalformedMetadataAndDeclarationsDoNotBecomeDefaults() throws {
        for json in ["[]", "null", "{", #"{"general":null}"#, #"{"general":{"properties":[]}}"#, #"{"preset":false}"#] {
            XCTAssertThrowsError(try ScenePropertyCatalog(projectJSON: Data(json.utf8)))
        }
        for declaration in [#"{"type":"bool","value":1}"#, #"{"type":"slider","value":0,"step":0}"#,
                            #"{"type":"combo","value":"a","options":[]}"#, #"{"type":"textinput","value":null}"#,
                            #"{"type":"bool","value":true,"text":1}"#] {
            let json = Data(("{\"general\":{\"properties\":{\"x\":" + declaration + "}}}").utf8)
            XCTAssertEqual(try ScenePropertyCatalog(projectJSON: json).rows.first?.readOnlyReason?.rawValue, "invalid-declaration")
        }
        XCTAssertEqual(try ScenePropertyCatalog(projectJSON: Data("{}".utf8)).rows, [])
    }

    func testScalarCodingAcceptsOnlyFiniteJSONScalars() throws {
        for value in [ScenePropertyValue.boolean(true), .number(0.75), .string("雪\n😀")] {
            XCTAssertEqual(try JSONDecoder().decode(ScenePropertyValue.self, from: JSONEncoder().encode(value)), value)
        }
        for json in ["null", "[]", "{}"] { XCTAssertThrowsError(try JSONDecoder().decode(ScenePropertyValue.self, from: Data(json.utf8))) }
        XCTAssertThrowsError(try JSONEncoder().encode(ScenePropertyValue.number(.infinity)))
    }

    func testMediaPersistenceLegacyDefaultAndBackendValidation() throws {
        let reference = SceneProjectReference(root: URL(fileURLWithPath: "/tmp/property-scene"), entry: "scene.json", representation: .loose)
        var item = MediaItem(url: reference.entryURL, kind: .scene, width: 640, height: 360,
                             backend: .scene, sceneProject: reference)
        let legacy = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! NSDictionary).mutableCopy() as! NSMutableDictionary
        legacy.removeObject(forKey: "scenePropertyOverrides")
        let old = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: old).scenePropertyOverrides, [])
        legacy.setObject(NSNull(), forKey: "scenePropertyOverrides" as NSString)
        XCTAssertThrowsError(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: legacy)))
        item.scenePropertyOverrides = [.init(name: "é", value: .string("one")), .init(name: "e\u{301}", value: .string("two"))]
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item)), item)
        XCTAssertNoThrow(try item.validateBackend(schema: Library.currentVersion))
        item.scenePropertyOverrides.append(item.scenePropertyOverrides[0])
        XCTAssertThrowsError(try item.validateBackend(schema: Library.currentVersion))
        var video = MediaItem(url: URL(fileURLWithPath: "/tmp/clip.mp4"), kind: .video, width: 10, height: 10)
        video.scenePropertyOverrides = [.init(name: "caption", value: .string("bad"))]
        XCTAssertThrowsError(try video.validateBackend(schema: Library.currentVersion))
    }
}
