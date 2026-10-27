import Foundation
import XCTest
import WallpaperEditorCore
@testable import EditorApp

final class EditorBindingDocumentTests: XCTestCase {
    private let script = "// 保留绑定来源 🌙\r\nexport function update(value) {\r\n    return value;\r\n}\r\n"
    private let fallback = "原始文本 😀\r\n第二行 e\u{301}\r\n"

    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/SceneAnimatedPackage")
    }

    // Preserve canonically equivalent property keys independently in Foundation.
    // Swift's [String: Any] would collapse these two authored names.
    private func properties() throws -> NSDictionary {
        let json = #"""
        {
          "enabled":{"type":"bool","value":true},
          "é":{"type":"slider","value":0.6,"min":0,"max":1},
          "e\u0301":{"type":"slider","value":30,"min":1,"max":60},
          "tint":{"type":"color","value":"0.2 0.4 0.8"},
          "caption":{"type":"textinput","value":"用户文本"},
          "模式":{"type":"combo","value":"e\u0301","options":[
            {"label":"Composed","value":"é"},
            {"label":"Decomposed","value":"e\u0301"}
          ]}
        }
        """#
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    private func boundScene(_ original: [String: Any]) -> [String: Any] {
        var scene = original
        scene["objects"] = [
            ["id": 11, "name": "绑定文本", "visible": ["value": false, "user": "enabled"],
             "alpha": ["value": 0.25, "user": "é", "script": script,
                       "scriptproperties": ["amount": 3, "future": ["keep": true]],
                       "animation": ["future": ["times": [0, 1]]],
                       "future": ["nullable": NSNull(), "unicode": "雪 😀"]],
             "color": ["value": "0.1 0.5 1", "user": "tint", "future": ["keep": [1, 2, 3]]],
             "text": ["value": fallback, "user": "caption", "future": ["format": "plain"]],
             "pointsize": ["value": 24, "user": "e\u{301}", "future": ["unit": "pt"]],
             "future": ["layer": "preserve"]] as [String: Any],
            ["id": 12, "name": "条件可见性", "solid": true, "size": "20 20",
             "visible": ["value": true,
                         "user": ["name": "模式", "condition": "e\u{301}", "future": ["keep": true]],
                         "future": ["branch": 9]]] as [String: Any],
        ]
        scene["future"] = ["scene": ["keep": true]]
        return scene
    }

    private func assertScene(_ value: Any?, equals expected: NSDictionary,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let scene = try XCTUnwrap(value as? NSDictionary, file: file, line: line)
        XCTAssertEqual(scene, expected, file: file, line: line)
        let layers = try XCTUnwrap(scene["objects"] as? [NSDictionary], file: file, line: line)
        let alpha = try XCTUnwrap(layers[0]["alpha"] as? NSDictionary, file: file, line: line)
        let text = try XCTUnwrap(layers[0]["text"] as? NSDictionary, file: file, line: line)
        let size = try XCTUnwrap(layers[0]["pointsize"] as? NSDictionary, file: file, line: line)
        let visible = try XCTUnwrap(layers[1]["visible"] as? NSDictionary, file: file, line: line)
        let conditional = try XCTUnwrap(visible["user"] as? NSDictionary, file: file, line: line)
        for (actual, expectedText) in [(alpha["script"], script), (text["value"], fallback),
                                       (alpha["user"], "é"), (size["user"], "e\u{301}"),
                                       (conditional["condition"], "e\u{301}")] {
            let string = try XCTUnwrap(actual as? String, file: file, line: line)
            XCTAssertEqual(Array(string.utf8), Array(expectedText.utf8), file: file, line: line)
        }
    }

    private func assertProperties(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws {
        let project = try XCTUnwrap(value as? NSDictionary, file: file, line: line)
        let general = try XCTUnwrap(project["general"] as? NSDictionary, file: file, line: line)
        let actual = try XCTUnwrap(general["properties"] as? NSDictionary, file: file, line: line)
        XCTAssertEqual(actual, try properties(), file: file, line: line)
        XCTAssertEqual(actual.count, 6, file: file, line: line)
        let composed = try XCTUnwrap(actual.object(forKey: "é" as NSString) as? NSDictionary, file: file, line: line)
        let decomposed = try XCTUnwrap(actual.object(forKey: "e\u{301}" as NSString) as? NSDictionary, file: file, line: line)
        XCTAssertEqual(composed["value"] as? Double, 0.6, file: file, line: line)
        XCTAssertEqual(decomposed["value"] as? Int, 30, file: file, line: line)
    }

    func testBindingsSurviveSnapshotSaveFreshStoreBrowserAndLooseExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(directory: root.appendingPathComponent("Projects"))
        let owned = try await store.importProject(root: fixture)
        var snapshot = try await EditorWindowController.browserDocument(owned.document)
        let scene = boundScene(try XCTUnwrap(snapshot["scene"] as? [String: Any]))
        var project = try XCTUnwrap(snapshot["project"] as? [String: Any])
        project["general"] = ["properties": try properties(), "future": ["keep": true]]
        snapshot["scene"] = scene
        snapshot["project"] = project
        snapshot["title"] = "绑定持久化"
        let draft = try await EditorWindowController.snapshotDocument(snapshot, basedOn: owned.document)
        let expected = NSDictionary(dictionary: scene)
        try assertScene(JSONSerialization.jsonObject(with: draft.scene), equals: expected)
        try assertProperties(JSONSerialization.jsonObject(with: draft.project))
        let saved = try await store.save(owned.document, scene: draft.scene, project: draft.project, title: draft.title)
        XCTAssertEqual(saved.revision, owned.document.revision + 1)

        let reopenedStore = EditorProjectStore(directory: store.directory)
        let reopened = try await reopenedStore.open(id: saved.id)
        XCTAssertEqual(reopened.document, saved)
        let browser = try await EditorWindowController.browserDocument(reopened.document)
        try assertScene(browser["scene"], equals: expected)
        try assertProperties(browser["project"])
        let workspaceURL = store.directory.appendingPathComponent(saved.id.uuidString).appendingPathComponent("workspace.json")
        let workspace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workspaceURL)) as? NSDictionary)
        try assertScene(workspace["scene"], equals: expected)
        try assertProperties(workspace["project"])

        let loose = try await reopenedStore.exportLoose(reopened.document, to: root.appendingPathComponent("Loose"))
        try assertScene(JSONSerialization.jsonObject(with: Data(contentsOf: loose.entryURL)), equals: expected)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: loose.root.appendingPathComponent("project.json"))) as? NSDictionary)
        try assertProperties(metadata)
        XCTAssertEqual(metadata["file"] as? String, "scene.json")
        XCTAssertEqual(metadata["title"] as? String, "绑定持久化")

        // The original real package cannot represent the newly authored scene.
        // A successful bound-scene PKG export must use the browser's real encoder.
        let packageDestination = root.appendingPathComponent("StalePackage")
        do {
            _ = try await reopenedStore.exportPackage(reopened.document,
                package: Data(contentsOf: fixture.appendingPathComponent("scene.pkg")), to: packageDestination)
            XCTFail("A stale package must not publish an unbound scene")
        } catch {
            XCTAssertEqual(error.localizedDescription, "PKG 场景与当前保存的工程不符。")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageDestination.path))
    }
}
