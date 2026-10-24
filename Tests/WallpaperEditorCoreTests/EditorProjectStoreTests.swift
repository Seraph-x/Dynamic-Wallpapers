import Foundation
import XCTest
import WallpaperCore
@testable import WallpaperEditorCore

final class EditorProjectStoreTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func store() -> EditorProjectStore { EditorProjectStore(directory: temporary.appendingPathComponent("Projects")) }

    func testNewSaveReopenAndRevisionConflict() async throws {
        let store = store()
        let created = try await store.create(title: "新 场景", width: 800, height: 600)
        XCTAssertEqual(created.document.title, "新 场景")
        let scene = try JSONSerialization.jsonObject(with: created.document.scene) as! [String: Any]
        XCTAssertEqual(((scene["general"] as! [String: Any])["orthogonalprojection"] as! [String: Int])["width"], 800)
        let saved = try await store.save(created.document, scene: Data("{\"objects\":[],\"unknown\":{\"x\":42}}".utf8), project: created.document.project, title: "Saved")
        XCTAssertEqual(saved.revision, created.document.revision + 1)
        let reopened = try await self.store().open(id: created.document.id)
        XCTAssertEqual(reopened.document, saved)
        do { _ = try await store.save(created.document, scene: saved.scene, project: saved.project, title: "Stale"); XCTFail("Stale save replaced newer work") } catch {}
        let afterConflict = try await store.open(id: saved.id)
        XCTAssertEqual(afterConflict.document.title, "Saved")
        do { _ = try await store.create(title: "", width: 0, height: -1); XCTFail() } catch {}
    }
    func testImportOwnsCompleteCopyAndLooseExportPreservesUnknownData() async throws {
        let source = temporary.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let scene = Data("{\"objects\":[],\"future\":[1,{\"x\":true}]}".utf8)
        let project = Data("{\"title\":\"Imported\",\"type\":\"scene\",\"file\":\"scene.json\",\"future\":42}".utf8)
        try scene.write(to: source.appendingPathComponent("scene.json")); try project.write(to: source.appendingPathComponent("project.json"))
        try Data([0, 1, 2]).write(to: source.appendingPathComponent("unknown.bin"))
        let store = store()
        let owned = try await store.importProject(root: source)
        XCTAssertNotEqual(owned.resources, source)
        let saved = try await store.save(owned.document, scene: scene, project: project, title: "Changed")
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("project.json")), project)
        let destination = temporary.appendingPathComponent("Export")
        let exported = try await store.exportLoose(saved, to: destination)
        XCTAssertEqual(exported.entry, "scene.json")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("unknown.bin")), Data([0, 1, 2]))
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("project.json"))) as! [String: Any]
        XCTAssertEqual(metadata["future"] as? Int, 42); XCTAssertEqual(metadata["title"] as? String, "Changed")
        do { _ = try await store.exportLoose(saved, to: destination); XCTFail("Existing export overwritten") } catch {}
    }
    func testPackageImportExtractsBeforeEditingAndDropsStaleContainerOnExport() async throws {
        let source = temporary.appendingPathComponent("Package")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{\"type\":\"scene\",\"title\":\"Package\",\"file\":\"scene.json\"}".utf8).write(to: source.appendingPathComponent("project.json"))
        let pkg = ScenePackageReaderTests.package([("scene.json", Data("{\"objects\":[]}".utf8)), ("extra.bin", Data([5]))])
        try pkg.write(to: source.appendingPathComponent("scene.pkg"))
        let store = store(); let owned = try await store.importProject(root: source)
        XCTAssertEqual(try Data(contentsOf: owned.resources.appendingPathComponent("extra.bin")), Data([5]))
        let exported = try await store.exportLoose(owned.document, to: temporary.appendingPathComponent("Export"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.root.appendingPathComponent("scene.pkg").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("scene.pkg")), pkg)
    }
    func testInvalidDocumentAndSymbolicLinkAreVisibleFailures() async throws {
        let store = store(); let created = try await store.create(title: "A", width: 1, height: 1)
        do { _ = try await store.save(created.document, scene: Data("[]".utf8), project: created.document.project, title: "Bad"); XCTFail() } catch {}
        let file = created.resources.deletingLastPathComponent().appendingPathComponent("workspace.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: temporary.appendingPathComponent("target"))
        do { _ = try await store.open(id: created.document.id); XCTFail() } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("target").path))
    }
    func testRedirectedStoreRootCannotReadOrOverwriteOtherDirectories() async throws {
        let store = store(); let created = try await store.create(title: "Original", width: 10, height: 10)
        let root = temporary.appendingPathComponent("Projects"), moved = temporary.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        let savedBytes = try Data(contentsOf: moved.appendingPathComponent(created.document.id.uuidString + "/workspace.json"))
        do { _ = try await store.open(id: created.document.id); XCTFail("Followed redirected root") } catch {}
        do { _ = try await store.save(created.document, scene: created.document.scene, project: created.document.project, title: "Overwrite"); XCTFail("Wrote through redirected root") } catch {}
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(created.document.id.uuidString + "/workspace.json")), savedBytes)
    }
}
