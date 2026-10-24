import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SceneManagedImportTests: XCTestCase {
    func testSceneImportOwnsWholeProjectAndPreservesMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Original scene")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        try Data(#"{"type":"scene","file":"scene.json","title":"Authored scene"}"#.utf8).write(to: root.appendingPathComponent("project.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("scene.json"))
        try Data("asset".utf8).write(to: root.appendingPathComponent("texture.bin"))
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        model.section = .playlist(try XCTUnwrap(model.library.playlists.first?.id))
        let reference = try XCTUnwrap(SceneProjectProbe.inspect(root: root).sceneProject)
        let imported = await model.importSceneProject(reference)
        XCTAssertTrue(imported)
        XCTAssertNil(model.failure)
        let item = try XCTUnwrap(model.library.media.first)
        let owned = try XCTUnwrap(item.sceneProject)
        XCTAssertNotEqual(owned.root, root)
        XCTAssertEqual(item.origin?.projectRoot, root.standardizedFileURL)
        XCTAssertEqual(item.name, "Authored scene")
        XCTAssertEqual(model.library.playlists[0].entries[0].timing.mode, .seconds)
        XCTAssertEqual(try store.load(), model.library)
        let repeated = await model.importSceneProject(reference)
        XCTAssertTrue(repeated)
        XCTAssertEqual(model.library.media.count, 1)
        try FileManager.default.removeItem(at: root)
        XCTAssertEqual(try Data(contentsOf: owned.root.appendingPathComponent("texture.bin")), Data("asset".utf8))
        try await model.shutdownAndWait()
    }

    func testSceneSaveFailureRollsBackOwnedCopyAndKeepsOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        try Data(#"{"type":"scene","file":"scene.json"}"#.utf8).write(to: root.appendingPathComponent("project.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("scene.json"))
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        let reference = try XCTUnwrap(SceneProjectProbe.inspect(root: root).sceneProject)
        let imported = await model.importSceneProject(reference)
        XCTAssertFalse(imported)
        XCTAssertNotNil(model.failure)
        XCTAssertTrue(model.library.media.isEmpty)
        XCTAssertNil(model.selectedMediaID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Media").path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.entryURL.path))
        try await model.shutdownAndWait()
    }
}
