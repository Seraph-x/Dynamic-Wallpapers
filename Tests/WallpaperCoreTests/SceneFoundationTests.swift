import XCTest
@testable import WallpaperCore

final class SceneFoundationTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/scene-project")

    func testSceneReferenceRejectsUnsafePathsAndRepresentationMismatch() throws {
        for entry in ["", "../scene.json", "/scene.json", "a/../scene.json", "a//scene.json", "./scene.json", "https://host/scene.json", "a\\scene.json", "a\0.json"] {
            XCTAssertThrowsError(try SceneProjectReference(root: root, entry: entry, representation: .loose).validate(), entry)
        }
        XCTAssertThrowsError(try SceneProjectReference(root: root, entry: "scene.pkg", representation: .loose).validate())
        XCTAssertThrowsError(try SceneProjectReference(root: URL(string: "https://host/project")!, entry: "scene.json", representation: .loose).validate())
        try SceneProjectReference(root: root, entry: "资源/scene.json", representation: .loose).validate()
        try SceneProjectReference(root: root, entry: "scene.pkg", representation: .package).validate()
    }

    func testSceneRoundTripsOnlyInSchemaFourWithMatchingBackendAndEntry() throws {
        let reference = SceneProjectReference(root: root, entry: "scene.pkg", representation: .package)
        let item = MediaItem(url: reference.entryURL, kind: .scene, width: 640, height: 360,
                             backend: .scene, sceneProject: reference)
        XCTAssertTrue(item.supportsAudio)
        XCTAssertEqual(item.name, "scene-project")
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item)), item)
        try item.validateBackend(schema: 4)
        for schema in 1...3 { XCTAssertThrowsError(try item.validateBackend(schema: schema)) }
        for invalid in [
            MediaItem(url: reference.entryURL, kind: .scene, width: 1, height: 1, sceneProject: reference),
            MediaItem(url: reference.entryURL, kind: .image, width: 1, height: 1, backend: .scene, sceneProject: reference),
            MediaItem(url: reference.entryURL, kind: .scene, width: 1, height: 1, duration: 2, backend: .scene, sceneProject: reference),
            MediaItem(url: root.appendingPathComponent("other.pkg"), kind: .scene, width: 1, height: 1, backend: .scene, sceneProject: reference)
        ] { XCTAssertThrowsError(try invalid.validateBackend(schema: 4)) }
        var library = Library.empty
        library.media = [item]
        library.playlists[0].entries = [PlaylistEntry(mediaID: item.id, timing: EntryTiming(mode: .full))]
        XCTAssertThrowsError(try library.validate())
    }

    func testVersionThreeLoadsWithoutRewritingThenSavesVersionFour() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        var legacy = Library.empty
        legacy.version = 3
        let bytes = try JSONEncoder().encode(legacy)
        try bytes.write(to: url)
        let store = LibraryStore(url: url)
        let loaded = try store.load()
        XCTAssertEqual(loaded.version, 4)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try store.save(loaded)
        XCTAssertEqual(try JSONDecoder().decode(Library.self, from: Data(contentsOf: url)).version, 4)
    }

    func testSceneOwnedCopyCommitDiscardAndRemovalPreserveOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("package bytes".utf8).write(to: root.appendingPathComponent("scene.pkg"))
        try Data("metadata".utf8).write(to: root.appendingPathComponent("project.json"))
        let reference = SceneProjectReference(root: root, entry: "scene.pkg", representation: .package)
        let store = ManagedMediaStore(directory: directory.appendingPathComponent("Media"))
        let copy = try await store.stage(source: .scene(reference))
        let staged = try XCTUnwrap(copy.stagedSceneProject)
        XCTAssertEqual(try Data(contentsOf: staged.root.appendingPathComponent("project.json")), Data("metadata".utf8))
        try await store.commit(copy)
        let item = copy.item(from: MediaItem(url: staged.entryURL, kind: .scene, width: 640, height: 360, backend: .scene, sceneProject: staged))
        XCTAssertEqual(item.sceneProject, copy.sceneProject)
        XCTAssertEqual(item.origin?.projectRoot, root.standardizedFileURL)
        try item.validateBackend(schema: 4)
        try await store.remove(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.entryURL.path))
        let discarded = try await store.stage(source: .scene(reference))
        try await store.discard(discarded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
    }
    func testSceneCopyRejectsExternalSymlinkAndRecursiveMediaRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = directory.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let outside = directory.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("scene.json"), withDestinationURL: outside)
        let reference = SceneProjectReference(root: project, entry: "scene.json", representation: .loose)
        let store = ManagedMediaStore(directory: directory.appendingPathComponent("Media"))
        do { _ = try await store.stage(source: .scene(reference)); XCTFail("External symlink was copied") }
        catch { XCTAssertTrue(error.localizedDescription.contains("项目")) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [])
        let recursive = ManagedMediaStore(directory: project.appendingPathComponent("Media"))
        do { _ = try await recursive.stage(source: .scene(reference)); XCTFail("Recursive project was copied") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Media")) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("{}".utf8))
    }

}
