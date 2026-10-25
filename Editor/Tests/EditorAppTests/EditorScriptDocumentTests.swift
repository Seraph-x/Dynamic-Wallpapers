import Foundation
import XCTest
import WallpaperEditorCore
@testable import EditorApp

final class EditorScriptDocumentTests: XCTestCase {
    func testSourceAndRemovalRoundTripThroughRealWorkspaceAndBrowserDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Script source", width: 10, height: 10)
        let source = "// 中文与星空 😀\r\nexport function update(value) {\r\n    return value;\r\n}\r\n"
        let wrapper: [String: Any] = [
            "value": 0.75,
            "script": source,
            "scriptproperties": ["script": ["custom": "元数据 🌙"], "amount": 3],
            "future": ["enabled": true, "values": [1, 2, 3]],
        ]
        let initial = try await EditorWindowController.browserDocument(owned.document)
        var scene = try XCTUnwrap(initial["scene"] as? [String: Any])
        scene["objects"] = [["id": 1, "name": "Script layer", "alpha": wrapper,
                              "future": ["note": "Keep layer metadata"]]]
        scene["future"] = ["note": "Keep scene metadata"]
        let saved = try await store.save(owned.document,
            scene: JSONSerialization.data(withJSONObject: scene), project: owned.document.project,
            title: owned.document.title)

        // Read through a new store and the real browser snapshot serializer. No
        // controller, renderer, or JavaScript execution host is instantiated.
        let reopenedStore = EditorProjectStore(directory: root)
        let reopened = try await reopenedStore.open(id: saved.id)
        XCTAssertEqual(reopened.document, saved)
        let browser = try await EditorWindowController.browserDocument(reopened.document)
        var reopenedScene = try XCTUnwrap(browser["scene"] as? [String: Any])
        var layers = try XCTUnwrap(reopenedScene["objects"] as? [[String: Any]])
        let reopenedWrapper = try XCTUnwrap(layers.first?["alpha"] as? [String: Any])
        let reopenedSource = try XCTUnwrap(reopenedWrapper["script"] as? String)
        XCTAssertEqual(Array(reopenedSource.utf8), Array(source.utf8))
        XCTAssertEqual(NSDictionary(dictionary: reopenedWrapper), NSDictionary(dictionary: wrapper))
        XCTAssertEqual(NSDictionary(dictionary: reopenedScene), NSDictionary(dictionary: scene))

        let workspaceURL = root.appendingPathComponent(saved.id.uuidString).appendingPathComponent("workspace.json")
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workspaceURL)) as? [String: Any])
        let persistedScene = try XCTUnwrap(persisted["scene"] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: persistedScene), NSDictionary(dictionary: scene))

        var removedWrapper = reopenedWrapper
        removedWrapper.removeValue(forKey: "script")
        layers[0]["alpha"] = removedWrapper
        reopenedScene["objects"] = layers
        let removed = try await reopenedStore.save(reopened.document,
            scene: JSONSerialization.data(withJSONObject: reopenedScene), project: reopened.document.project,
            title: reopened.document.title)
        let finalStore = EditorProjectStore(directory: root)
        let finalProject = try await finalStore.open(id: removed.id)
        XCTAssertEqual(finalProject.document, removed)
        let finalBrowser = try await EditorWindowController.browserDocument(finalProject.document)
        let finalScene = try XCTUnwrap(finalBrowser["scene"] as? [String: Any])
        let finalLayers = try XCTUnwrap(finalScene["objects"] as? [[String: Any]])
        let finalWrapper = try XCTUnwrap(finalLayers.first?["alpha"] as? [String: Any])
        XCTAssertNil(finalWrapper["script"])
        XCTAssertEqual(NSDictionary(dictionary: finalWrapper), NSDictionary(dictionary: removedWrapper))
        XCTAssertEqual(NSDictionary(dictionary: finalScene), NSDictionary(dictionary: reopenedScene))
        XCTAssertEqual(removed.revision, saved.revision + 1)
    }
}
