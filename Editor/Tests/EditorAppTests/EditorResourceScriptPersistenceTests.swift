import Foundation
import XCTest
import WallpaperEditorCore

final class EditorResourceScriptPersistenceTests: XCTestCase {
    private func package(_ entries: [(String, Data)]) -> Data {
        var bytes = Data(), offset = 0
        func number(_ value: Int) { var word = UInt32(value).littleEndian; bytes.append(Data(bytes: &word, count: 4)) }
        number(8); bytes.append(Data("PKGV0012".utf8)); number(entries.count)
        for (path, data) in entries { number(path.utf8.count); bytes.append(Data(path.utf8)); number(offset); number(data.count); offset += data.count }
        for (_, data) in entries { bytes.append(data) }
        return bytes
    }
    func testLooseAndPackageResourceScriptsSurviveNativeCaptureSaveReopenExportsAndCollection() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: temporary) }
        let materialPath = "materials/雪.a.json", particlePath = "particles/owned.json"
        let originalSource = "export function update(value){return value;}"
        let editedSource = "// 雪\r\nexport function update(value){return value * .5;}"
        func literal(_ source: String) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        }
        let material = "\u{feff}{\r\n// retained comment\r\n\"passes\":[{\"shader\":\"effects/owned\",\"constantshadervalues\":{\"Value\":{\"value\":1e+0,\"script\":\(try literal(originalSource)),\"huge\":9007199254740993,\"future\":1,\"future\":2}}}]\r\n}"
        let particle = "{\r\n\"emitter\":[{\"rate\":{\"value\":1,\"script\":\(try literal(originalSource)),\"future\":{\"keep\":true}}}],\"huge\":9007199254740993\r\n}"
        let originals = [materialPath: Data(material.utf8), particlePath: Data(particle.utf8), "unknown.json": Data("{\"future\":1,\"future\":2,\"huge\":9007199254740993}\r\n".utf8)]
        let edited = try originals.mapValues { bytes in
            Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: try literal(originalSource), with: try literal(editedSource)).utf8)
        }
        let scene = Data(#"{"objects":[{"id":1,"particle":"particles/owned.json"}],"future":{"keep":true}}"#.utf8)
        for package in [false, true] {
            let root = temporary.appendingPathComponent(package ? "PackageSource" : "LooseSource")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let entries = [("scene.json", scene)] + originals.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
            let originalPackage = self.package(entries)
            if package { try originalPackage.write(to: root.appendingPathComponent("scene.pkg")) }
            else {
                for (path, bytes) in entries {
                    let url = root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url)
                }
            }
            let metadata = try JSONSerialization.data(withJSONObject: ["type": "scene", "title": "Resources", "file": package ? "scene.pkg" : "scene.json"])
            try metadata.write(to: root.appendingPathComponent("project.json"))
            let store = EditorProjectStore(directory: temporary.appendingPathComponent(package ? "PackageStore" : "LooseStore"))
            let owned = try await store.importProject(root: root)
            for (path, bytes) in originals { XCTAssertEqual(try Data(contentsOf: owned.resources.appendingPathComponent(path)), bytes) }
            var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
            var overrides: [String: EditorResourceVersion] = [:]
            for path in [materialPath, particlePath] {
                overrides[path] = try await store.stageResource(id: owned.document.id, data: edited[path]!, session: session!)
            }
            let history = try await store.stageResource(id: owned.document.id, data: Data((material + "\r\n ").utf8), session: session!)
            let draft = try EditorProjectDocument(id: owned.document.id, revision: owned.document.revision, title: owned.document.title,
                sceneEntry: owned.document.sceneEntry, sourcePackage: owned.document.sourcePackage, scene: owned.document.scene,
                project: owned.document.project, resourceOverrides: overrides, schemaVersion: 2)
            let preview = try await store.exportPreview(draft, basedOn: owned.document, to: temporary.appendingPathComponent(package ? "PackagePreview" : "LoosePreview"))
            for path in [materialPath, particlePath] { XCTAssertEqual(try Data(contentsOf: preview.root.appendingPathComponent(path)), edited[path]) }
            let unchanged = try await store.open(id: owned.document.id)
            XCTAssertEqual(unchanged.document, owned.document)
            let active = try await store.collectUnusedResources(id: owned.document.id)
            XCTAssertTrue(active.activeSession); XCTAssertTrue(active.removedVersions.isEmpty)
            let saved = try await store.save(owned.document, scene: owned.document.scene, project: owned.document.project,
                title: owned.document.title, resourceOverrides: overrides)
            let fresh = EditorProjectStore(directory: store.directory), reopened = try await fresh.open(id: saved.id)
            XCTAssertEqual(reopened.document, saved)
            let loose = try await fresh.exportLoose(saved, to: temporary.appendingPathComponent(package ? "PackageLooseExport" : "LooseExport"))
            for (path, bytes) in edited { XCTAssertEqual(try Data(contentsOf: loose.root.appendingPathComponent(path)), bytes) }
            let exportedPackage = self.package([("scene.json", saved.scene)] + edited.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) })
            let exported = try await fresh.exportPackage(saved, package: exportedPackage, to: temporary.appendingPathComponent(package ? "PackagePackageExport" : "LoosePackageExport"))
            let reimported = try await fresh.importProject(root: exported.root)
            for (path, bytes) in edited { XCTAssertEqual(try Data(contentsOf: reimported.resources.appendingPathComponent(path)), bytes) }
            for (path, bytes) in originals { XCTAssertEqual(try Data(contentsOf: owned.resources.appendingPathComponent(path)), bytes) }
            if package { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("scene.pkg")), originalPackage) }
            session = nil
            let collection = try await fresh.collectUnusedResources(id: saved.id)
            XCTAssertEqual(collection.removedVersions, [history.id])
            for (path, version) in overrides { let bytes = try await fresh.resource(id: saved.id, version: version); XCTAssertEqual(bytes, edited[path]) }
        }
    }
}
