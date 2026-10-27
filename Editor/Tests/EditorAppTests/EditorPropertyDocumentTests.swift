import Foundation
import XCTest
import WallpaperEditorCore
@testable import EditorApp

final class EditorPropertyDocumentTests: XCTestCase {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/SceneAnimatedPackage")
    }

    // Foundation dictionaries retain the two exact JSON keys. A Swift String
    // dictionary would merge these canonically equivalent Unicode names.
    private func declarations() throws -> NSDictionary {
        let json = #"""
        {
          "é": {"type":"textinput","text":"Composed","value":"first"},
          "e\u0301": {"type":"textinput","text":"Decomposed","value":"second"},
          "speed": {"type":"slider","value":1.75,"min":-2,"max":4,"step":0.25,"future":{"keep":[1,true,"雪"]}},
          "enabled": {"type":"bool","value":false},
          "tint": {"type":"color","value":"0.1 0.5 1"},
          "mode": {"type":"combo","value":"night","options":[
            {"label":"Day","value":"day","future":{"icon":"sun","nullable":null}},
            {"label":"Night","value":"night","future":{"icon":"moon","order":7}}
          ],"future":["keep",3]},
          "unknown": {"type":"future-control","value":{"nested":[false,2,"🌙"]},"condition":"enabled","future":{"version":9}}
        }
        """#
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    private func authoredProject(_ data: Data) throws -> [String: Any] {
        var project = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        project["general"] = ["properties": try declarations(), "future": ["keep": true]]
        project["preset"] = ["futurePreset": ["value": "preserve"]]
        project["future"] = ["document": [1, 2, 3]]
        return project
    }

    private func assertDeclarations(_ project: Any?, file: StaticString = #filePath, line: UInt = #line) throws {
        let metadata = try XCTUnwrap(project as? NSDictionary, file: file, line: line)
        let general = try XCTUnwrap(metadata["general"] as? NSDictionary, file: file, line: line)
        let properties = try XCTUnwrap(general["properties"] as? NSDictionary, file: file, line: line)
        XCTAssertEqual(properties.count, 7, file: file, line: line)
        let composed = try XCTUnwrap(properties.object(forKey: "é" as NSString) as? NSDictionary, file: file, line: line)
        let decomposed = try XCTUnwrap(properties.object(forKey: "e\u{301}" as NSString) as? NSDictionary, file: file, line: line)
        XCTAssertEqual(composed["value"] as? String, "first", file: file, line: line)
        XCTAssertEqual(decomposed["value"] as? String, "second", file: file, line: line)
        XCTAssertEqual(properties, try declarations(), file: file, line: line)
    }

    private func assertExportMetadata(_ url: URL, expected: NSDictionary, entry: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary,
                                     file: file, line: line)
        XCTAssertEqual(metadata["file"] as? String, entry, file: file, line: line)
        XCTAssertEqual(metadata["title"] as? String, "Property definitions", file: file, line: line)
        for key in ["general", "preset", "future"] {
            XCTAssertEqual(metadata[key] as? NSObject, expected[key] as? NSObject, file: file, line: line)
        }
        try assertDeclarations(metadata, file: file, line: line)
    }

    func testDefinitionsSurviveSnapshotSaveReopenBrowserAndBothExportMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(directory: root.appendingPathComponent("Projects"))
        let owned = try await store.importProject(root: fixture)
        var snapshot = try await EditorWindowController.browserDocument(owned.document)
        let originalScene = try XCTUnwrap(snapshot["scene"] as? NSDictionary)
        let expectedProject = try authoredProject(owned.document.project)
        snapshot["project"] = expectedProject
        snapshot["title"] = "Property definitions"
        let draft = try await EditorWindowController.snapshotDocument(snapshot, basedOn: owned.document)
        try assertDeclarations(JSONSerialization.jsonObject(with: draft.project))
        let saved = try await store.save(owned.document, scene: draft.scene, project: draft.project, title: draft.title)

        // Reopen through a distinct store to exercise workspace persistence and
        // browser serialization without starting a renderer or native window.
        let reopenedStore = EditorProjectStore(directory: store.directory)
        let reopened = try await reopenedStore.open(id: saved.id)
        XCTAssertEqual(reopened.document, saved)
        XCTAssertEqual(saved.revision, owned.document.revision + 1)
        let browser = try await EditorWindowController.browserDocument(reopened.document)
        try assertDeclarations(browser["project"])
        XCTAssertEqual(browser["project"] as? NSDictionary, NSDictionary(dictionary: expectedProject))
        XCTAssertEqual(browser["scene"] as? NSDictionary, originalScene)
        let workspaceURL = store.directory.appendingPathComponent(saved.id.uuidString).appendingPathComponent("workspace.json")
        let workspace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workspaceURL)) as? NSDictionary)
        try assertDeclarations(workspace["project"])

        let loose = try await reopenedStore.exportLoose(reopened.document, to: root.appendingPathComponent("Loose"))
        try assertExportMetadata(loose.root.appendingPathComponent("project.json"),
                                 expected: NSDictionary(dictionary: expectedProject), entry: "scene.json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: loose.entryURL)) as? NSDictionary, originalScene)

        // Use the real checked-in package, whose scene is unchanged by property
        // definition edits. This does not substitute a test package encoder.
        let packageBytes = try Data(contentsOf: fixture.appendingPathComponent("scene.pkg"))
        let package = try await reopenedStore.exportPackage(reopened.document, package: packageBytes,
                                                            to: root.appendingPathComponent("Package"))
        try assertExportMetadata(package.root.appendingPathComponent("project.json"),
                                 expected: NSDictionary(dictionary: expectedProject), entry: "scene.pkg")
        let exportedBytes = try Data(contentsOf: package.entryURL)
        XCTAssertEqual(exportedBytes, packageBytes)
        let packagedScene = try ScenePackageReader(data: exportedBytes).read("scene.json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: packagedScene) as? NSDictionary, originalScene)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.root.appendingPathComponent("scene.json").path))
    }

    func testDefinitionSnapshotPreservesSceneScriptBindingAndUnknownWrapperFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Binding", width: 10, height: 10)
        let source = "// 中文 😀\r\nexport function update(value) { return value; }\r\n"
        let wrapper: [String: Any] = [
            "value": "0.1 0.5 1", "user": "tint", "script": source,
            "scriptproperties": ["amount": 3, "future": ["keep": true]],
            "future": ["values": [1, 2, 3]],
        ]
        var snapshot = try await EditorWindowController.browserDocument(owned.document)
        var scene = try XCTUnwrap(snapshot["scene"] as? [String: Any])
        scene["objects"] = [["id": 1, "name": "Bound script", "color": wrapper]]
        snapshot["scene"] = scene
        snapshot["project"] = try authoredProject(owned.document.project)
        let draft = try await EditorWindowController.snapshotDocument(snapshot, basedOn: owned.document)
        let saved = try await store.save(owned.document, scene: draft.scene, project: draft.project, title: draft.title)
        let reopenedStore = EditorProjectStore(directory: root)
        let reopened = try await reopenedStore.open(id: saved.id)
        let browser = try await EditorWindowController.browserDocument(reopened.document)
        try assertDeclarations(browser["project"])
        let reopenedScene = try XCTUnwrap(browser["scene"] as? NSDictionary)
        XCTAssertEqual(reopenedScene, NSDictionary(dictionary: scene))
        let objects = try XCTUnwrap(reopenedScene["objects"] as? [NSDictionary])
        let reopenedWrapper = try XCTUnwrap(objects.first?["color"] as? NSDictionary)
        XCTAssertEqual(reopenedWrapper, NSDictionary(dictionary: wrapper))
        XCTAssertEqual(Array(try XCTUnwrap(reopenedWrapper["script"] as? String).utf8), Array(source.utf8))
        XCTAssertEqual(reopenedWrapper["user"] as? String, "tint")
    }
}
