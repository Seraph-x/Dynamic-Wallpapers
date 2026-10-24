import Darwin
import XCTest
import WallpaperCore
@testable import WallpaperApp

final class SceneProjectProbeTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("project") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testDeclaredLooseSceneAndProjectNameUseNeutralViewport() throws {
        try metadata(["type": "scene", "file": "scene.json", "title": "Animated forest"])
        try write("scene.json", "{\"general\":{},\"objects\":[]}")
        let item = try SceneProjectProbe.inspect(root: root)
        XCTAssertEqual(item.kind, .scene)
        XCTAssertEqual(item.backend, .scene)
        XCTAssertEqual(item.sceneProject?.representation, .loose)
        XCTAssertEqual(item.sceneProject?.entry, "scene.json")
        XCTAssertEqual(item.customName, "Animated forest")
        XCTAssertEqual(item.width, 640)
        XCTAssertEqual(item.height, 360)
        XCTAssertNil(item.duration)
        try item.validateBackend(schema: 4)
    }

    func testDeclaredPackageAndConventionalPackedLayoutAreSelectedExplicitly() throws {
        try write("scene.pkg", "PKGV0001")
        for declared in ["scene.pkg", "scene.json"] {
            try metadata(["type": "Scene", "file": declared])
            let item = try SceneProjectProbe.inspect(root: root)
            XCTAssertEqual(item.sceneProject?.entry, "scene.pkg")
            XCTAssertEqual(item.sceneProject?.representation, .package)
        }
        try write("scene.json", "{}")
        XCTAssertEqual(try SceneProjectProbe.inspect(root: root).sceneProject?.representation, .loose)
    }

    func testUnsafeOrUnsupportedMetadataCannotSearchForAnAlternative() throws {
        try write("scene.pkg", "PKGV0001")
        for record: [String: Any] in [
            ["type": "application", "file": "scene.pkg"], ["type": "video", "file": "scene.pkg"],
            ["type": "scene"], ["type": "scene", "file": "../scene.json"],
            ["type": "scene", "file": "https://host/scene.json"],
            ["type": "scene", "file": "missing.json"], ["type": "scene", "file": "preview.mp4"],
            ["type": "scene", "file": "project.json"]
        ] {
            try metadata(record)
            XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root), "\(record)")
        }
        try write("project.json", "{broken")
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
    }

    func testMissingNonRegularMalformedAndSymlinkEntriesFail() throws {
        try metadata(["type": "scene", "file": "scene.json"])
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
        try write("scene.json", "not json")
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
        try write("scene.json", "[]")
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("scene.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scene.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("scene.json"))
        XCTAssertEqual(mkfifo(root.appendingPathComponent("scene.json").path, 0o600), 0)
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("scene.json"))
        let external = directory.appendingPathComponent("external.json")
        try Data("{}".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("scene.json"), withDestinationURL: external)
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
    }

    func testAssignedReferenceMustStillMatchMetadataAndRepresentation() throws {
        try metadata(["type": "scene", "file": "scene.json"])
        try write("scene.json", "{}")
        try write("other.json", "{}")
        XCTAssertThrowsError(try SceneProjectProbe.inspect(SceneProjectReference(root: root, entry: "other.json", representation: .loose)))
    }

    func testSceneFingerprintIncludesNonEntryResources() throws {
        try metadata(["type": "scene", "file": "scene.json"])
        try write("scene.json", "{}")
        try write("texture.png", "before")
        let item = try SceneProjectProbe.inspect(root: root)
        let before = try SystemWallpaperSourceVersionReader.fingerprint(for: item)
        try write("texture.png", "after with different size")
        XCTAssertNotEqual(try SystemWallpaperSourceVersionReader.fingerprint(for: item), before)
    }


    func testMetadataAndIntermediateDirectorySymlinksCannotRedirectInspection() throws {
        let external = directory.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("{}".utf8).write(to: external.appendingPathComponent("scene.json"))
        try metadata(["type": "scene", "file": "nested/scene.json"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("nested"), withDestinationURL: external)
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
        try FileManager.default.moveItem(at: root.appendingPathComponent("project.json"), to: external.appendingPathComponent("project.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("project.json"), withDestinationURL: external.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
    }

    func testInvalidPackageHeaderIsAnImportError() throws {
        try metadata(["type": "scene", "file": "scene.pkg"])
        for bytes in ["not a package", "PKGV"] {
            try write("scene.pkg", bytes)
            XCTAssertThrowsError(try SceneProjectProbe.inspect(root: root))
        }
    }

    private func metadata(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("project.json"))
    }
    private func write(_ path: String, _ value: String) throws {
        try Data(value.utf8).write(to: root.appendingPathComponent(path))
    }
}
