import Foundation
import XCTest
@testable import WallpaperEditorCore

final class EditorResourceTransactionTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func store() -> EditorProjectStore { EditorProjectStore(directory: temporary.appendingPathComponent("Projects")) }

    func testSchemaCompatibilityAndStrictResourceReferences() async throws {
        let owned = try await store().create(title: "Original", width: 10, height: 10)
        var json = try EditorProjectDocument.object(owned.document.encoded())
        XCTAssertEqual(json["schema"] as? Int, 1)
        let version = try EditorResourceVersion(id: String(repeating: "a", count: 64))
        json["schema"] = 2; json["resourceOverrides"] = ["models/body.mdl":version.id]
        let document = try EditorProjectDocument(data: EditorProjectDocument.encode(json))
        XCTAssertEqual(document.resourceOverrides, ["models/body.mdl": version])
        XCTAssertEqual(document.schemaVersion, 2)
        XCTAssertEqual(try EditorProjectDocument(data: document.encoded()), document)
        for path in ["../escape", "project.json", "scene.json", "a\\b", "/absolute"] {
            json["resourceOverrides"] = [path:version.id]
            XCTAssertThrowsError(try EditorProjectDocument(data: EditorProjectDocument.encode(json)))
        }
        for id in ["", String(repeating: "A", count: 64), "../x", String(repeating: "a", count: 63)] {
            XCTAssertThrowsError(try EditorResourceVersion(id: id))
        }
        json["resourceOverrides"] = [:]; json["extra"] = true
        XCTAssertThrowsError(try EditorProjectDocument(data: EditorProjectDocument.encode(json)))
    }

    func testResourceRevisionSaveReopenAndExports() async throws {
        let store = store(), owned = try await store.create(title: "Resources", width: 10, height: 10)
        let bytes = Data([9, 8, 7]), version = try await store.stageResource(id: owned.document.id, data: bytes)
        let duplicate = try await store.stageResource(id: owned.document.id, data: bytes)
        XCTAssertEqual(duplicate, version)
        let overrides = ["models/new.mdl":version]
        let saved = try await store.save(owned.document, scene: owned.document.scene, project: owned.document.project,
                                         title: "Edited", resourceOverrides: overrides)
        let reopened = try await self.store().open(id: saved.id)
        XCTAssertEqual(reopened.document, saved)
        let readBack = try await store.resource(id: saved.id, version: version)
        XCTAssertEqual(readBack, bytes)
        let paths = try await store.resourcePaths(id: saved.id)
        XCTAssertEqual(paths.filter { $0 == "models/new.mdl" }.count, 1)
        let exported = try await store.exportLoose(saved, to: temporary.appendingPathComponent("Export"))
        XCTAssertEqual(try Data(contentsOf: exported.root.appendingPathComponent("models/new.mdl")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.root.appendingPathComponent("Resources").path))
        let empty = try await store.save(saved, scene: saved.scene, project: saved.project, title: saved.title, resourceOverrides: [:])
        XCTAssertEqual(empty.schemaVersion, 2)
        XCTAssertTrue(empty.resourceOverrides.isEmpty)
        let legacy = try await store.create(title: "Legacy", width: 10, height: 10)
        let legacySaved = try await store.save(legacy.document, scene: legacy.document.scene, project: legacy.document.project, title: "Legacy saved")
        XCTAssertEqual(legacySaved.schemaVersion, 1)
    }

    func testMissingCorruptAndCrossWorkspaceBlobsCannotPublish() async throws {
        let store = store(), owned = try await store.create(title: "Original", width: 10, height: 10)
        let version = try await store.stageResource(id: owned.document.id, data: Data([1,2]))
        let other = try await store.create(title: "Other", width: 10, height: 10)
        do { _ = try await store.resource(id: other.document.id, version: version); XCTFail("Read another workspace") } catch {}
        let blob = owned.resources.deletingLastPathComponent().appendingPathComponent("Resources/" + version.id)
        try Data([3]).write(to: blob)
        do { _ = try await store.stageResource(id: owned.document.id, data: Data([1,2])); XCTFail("Overwrote corrupt blob") } catch {}
        do { _ = try await store.save(owned.document, scene: owned.document.scene, project: owned.document.project,
                                      title: "Invalid", resourceOverrides: ["a.bin":version]); XCTFail("Published corrupt reference") } catch {}
        let afterFailure = try await store.open(id: owned.document.id)
        XCTAssertEqual(afterFailure.document, owned.document)
        try FileManager.default.removeItem(at: blob)
        do { _ = try await store.resource(id: owned.document.id, version: version); XCTFail("Read missing blob") } catch {}
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: temporary.appendingPathComponent("Outside"))
        do { _ = try await store.stageResource(id: owned.document.id, data: Data([1,2])); XCTFail("Followed symlink") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("Outside").path))
    }

    func testSaveFailureAndConflictKeepPreviousResources() async throws {
        let store = store(), owned = try await store.create(title: "Original", width: 10, height: 10)
        let first = try await store.stageResource(id: owned.document.id, data: Data([1]))
        let saved = try await store.save(owned.document, scene: owned.document.scene, project: owned.document.project,
                                         title: "Saved", resourceOverrides: ["a.bin":first])
        let next = try await store.stageResource(id: saved.id, data: Data([2]))
        do { _ = try await store.save(owned.document, scene: saved.scene, project: saved.project,
                                      title: "Stale", resourceOverrides: ["a.bin":next]); XCTFail("Stale revision published") } catch {}
        let workspace = owned.resources.deletingLastPathComponent().appendingPathComponent("workspace.json")
        let previous = try Data(contentsOf: workspace)
        try FileManager.default.removeItem(at: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        do { _ = try await store.save(saved, scene: saved.scene, project: saved.project,
                                      title: "Failed", resourceOverrides: ["a.bin":next]); XCTFail("Invalid target written") } catch {}
        try FileManager.default.removeItem(at: workspace); try previous.write(to: workspace)
        let afterFailure = try await store.open(id: saved.id)
        let original = try await store.resource(id: saved.id, version: first)
        XCTAssertEqual(afterFailure.document, saved)
        XCTAssertEqual(original, Data([1]))
    }
}
