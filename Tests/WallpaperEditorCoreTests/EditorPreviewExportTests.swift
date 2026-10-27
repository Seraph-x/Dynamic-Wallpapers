import Foundation
import XCTest
import WallpaperCore
@testable import WallpaperEditorCore

final class EditorPreviewExportTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func store() -> EditorProjectStore { EditorProjectStore(directory: temporary.appendingPathComponent("Projects")) }
    private func draft(_ saved: EditorProjectDocument, title: String = "Unsaved", overrides: [String: EditorResourceVersion] = [:]) throws -> EditorProjectDocument {
        try EditorProjectDocument(id: saved.id, revision: saved.revision, title: title, sceneEntry: saved.sceneEntry,
            sourcePackage: saved.sourcePackage, scene: Data(#"{"objects":[],"future":{"value":42}}"#.utf8),
            project: Data(#"{"type":"scene","title":"Ignored","file":"ignored.json","future":[1,2]}"#.utf8),
            resourceOverrides: overrides, schemaVersion: saved.schemaVersion == 2 || !overrides.isEmpty ? 2 : 1)
    }
    private func assertRejected(_ draft: EditorProjectDocument, baseline: EditorProjectDocument,
                                store: EditorProjectStore, name: String = UUID().uuidString) async {
        let destination = temporary.appendingPathComponent(name)
        do { _ = try await store.exportPreview(draft, basedOn: baseline, to: destination); XCTFail("Published invalid preview") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUnsavedSnapshotOwnsSceneTitleMetadataAndResourceVersionsWithoutSaving() async throws {
        let store = store(), owned = try await store.create(title: "Saved", width: 10, height: 10)
        let original = Data([1,2,3]), replacement = Data([4,5,6])
        try original.write(to: owned.resources.appendingPathComponent("original.bin"))
        let session = try await store.acquireResourceSession(id: owned.document.id)
        defer { withExtendedLifetime(session) {} }
        let version = try await store.stageResource(id: owned.document.id, data: replacement, session: session)
        let draft = try draft(owned.document, overrides: ["original.bin": version, "models/new.bin": version])
        XCTAssertEqual(owned.document.schemaVersion, 1); XCTAssertEqual(draft.schemaVersion, 2)
        let workspace = owned.resources.deletingLastPathComponent().appendingPathComponent("workspace.json")
        let workspaceBytes = try Data(contentsOf: workspace), sceneBytes = try Data(contentsOf: owned.resources.appendingPathComponent("scene.json"))
        let exported = try await store.exportPreview(draft, basedOn: owned.document, to: temporary.appendingPathComponent("Preview"))
        XCTAssertEqual(exported.representation, .loose); XCTAssertEqual(exported.entry, owned.document.sceneEntry)
        XCTAssertEqual(try Data(contentsOf: exported.entryURL), draft.scene)
        let metadata = try EditorProjectDocument.object(Data(contentsOf: exported.root.appendingPathComponent("project.json")))
        XCTAssertEqual(metadata["title"] as? String, "Unsaved"); XCTAssertEqual(metadata["file"] as? String, "scene.json")
        XCTAssertEqual(metadata["future"] as? [Int], [1,2])
        for path in draft.resourceOverrides.keys { XCTAssertEqual(try Data(contentsOf: exported.root.appendingPathComponent(path)), replacement) }
        XCTAssertEqual(try Data(contentsOf: workspace), workspaceBytes)
        XCTAssertEqual(try Data(contentsOf: owned.resources.appendingPathComponent("scene.json")), sceneBytes)
        XCTAssertEqual(try Data(contentsOf: owned.resources.appendingPathComponent("original.bin")), original)
        let reopened = try await store.open(id: owned.document.id)
        XCTAssertEqual(reopened.document, owned.document)
        _ = try await store.save(owned.document, scene: Data(#"{"objects":[{"id":99}]}"#.utf8), project: owned.document.project, title: "Later")
        try Data([9]).write(to: owned.resources.appendingPathComponent("original.bin"))
        XCTAssertEqual(try Data(contentsOf: exported.entryURL), draft.scene)
        XCTAssertEqual(try Data(contentsOf: exported.root.appendingPathComponent("original.bin")), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.root.appendingPathComponent("workspace.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.root.appendingPathComponent("Resources").path))
    }

    func testRejectsMismatchedDraftIdentityRevisionEntryAndPackage() async throws {
        let store = store(), saved = try await store.create(title: "Saved", width: 10, height: 10).document
        let values = [(UUID(), saved.revision, saved.sceneEntry, saved.sourcePackage),
                      (saved.id, saved.revision + 1, saved.sceneEntry, saved.sourcePackage),
                      (saved.id, saved.revision, "other.json", saved.sourcePackage),
                      (saved.id, saved.revision, saved.sceneEntry, "other.pkg")]
        for (id, revision, entry, package) in values {
            let changed = try EditorProjectDocument(id: id, revision: revision, title: "Draft", sceneEntry: entry,
                sourcePackage: package, scene: saved.scene, project: saved.project)
            await assertRejected(changed, baseline: saved, store: store)
        }
    }

    func testRejectsStaleOrForgedSavedBaseline() async throws {
        let store = store(), saved = try await store.create(title: "Saved", width: 10, height: 10).document
        await assertRejected(try draft(saved), baseline: try draft(saved, title: "Forged"), store: store)
        let next = try await store.save(saved, scene: saved.scene, project: saved.project, title: "New baseline")
        await assertRejected(try draft(saved), baseline: saved, store: store)
        let current = try await store.open(id: saved.id).document
        XCTAssertEqual(current, next)
    }

    func testRejectsMissingCorruptCrossProjectAndSymlinkResources() async throws {
        let store = store(), saved = try await store.create(title: "Saved", width: 10, height: 10).document
        let other = try await store.create(title: "Other", width: 10, height: 10).document
        let otherSession = try await store.acquireResourceSession(id: other.id)
        defer { withExtendedLifetime(otherSession) {} }
        let version = try await store.stageResource(id: other.id, data: Data([1]), session: otherSession)
        let draft = try draft(saved, overrides: ["a.bin": version])
        await assertRejected(draft, baseline: saved, store: store)
        let session = try await store.acquireResourceSession(id: saved.id)
        defer { withExtendedLifetime(session) {} }
        _ = try await store.stageResource(id: saved.id, data: Data([1]), session: session)
        let blob = store.directory.appendingPathComponent("\(saved.id.uuidString)/Resources/\(version.id)")
        try Data([2]).write(to: blob)
        await assertRejected(draft, baseline: saved, store: store)
        try FileManager.default.removeItem(at: blob)
        await assertRejected(draft, baseline: saved, store: store)
        let target = temporary.appendingPathComponent("Outside")
        try Data([1]).write(to: target)
        try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: target)
        await assertRejected(draft, baseline: saved, store: store)
        XCTAssertEqual(try Data(contentsOf: target), Data([1]))
    }

    func testRejectsResourceAliasesFileDirectoryCollisionsAndProjectSymlinks() async throws {
        let store = store(), owned = try await store.create(title: "Saved", width: 10, height: 10)
        try FileManager.default.createDirectory(at: owned.resources.appendingPathComponent("models"), withIntermediateDirectories: true)
        try Data([1]).write(to: owned.resources.appendingPathComponent("models/body.bin"))
        let session = try await store.acquireResourceSession(id: owned.document.id)
        defer { withExtendedLifetime(session) {} }
        let version = try await store.stageResource(id: owned.document.id, data: Data([2]), session: session)
        for path in ["Models/body.bin", "models/BODY.bin", "models", "models/body.bin/child"] {
            await assertRejected(try draft(owned.document, overrides: [path: version]), baseline: owned.document, store: store)
        }
        try FileManager.default.createSymbolicLink(at: owned.resources.appendingPathComponent("link"), withDestinationURL: temporary)
        await assertRejected(try draft(owned.document), baseline: owned.document, store: store)
    }

    func testInvalidDestinationsAndExistingFilesAreNeverOverwritten() async throws {
        let store = store(), saved = try await store.create(title: "Saved", width: 10, height: 10).document
        let draft = try draft(saved)
        for destination in [URL(string: "https://example.com/preview")!, temporary.appendingPathComponent("missing/preview")] {
            do { _ = try await store.exportPreview(draft, basedOn: saved, to: destination); XCTFail("Accepted invalid destination") } catch {}
        }
        let destination = temporary.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data([7]).write(to: destination.appendingPathComponent("sentinel"))
        do { _ = try await store.exportPreview(draft, basedOn: saved, to: destination); XCTFail("Overwrote existing destination") } catch {}
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("sentinel")), Data([7]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporary.path).contains { $0.hasPrefix(".editor-export-") })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).contains { $0.hasPrefix(".import-") })
    }

    func testConcurrentSaveDuringMediaStageRejectsPreviewBeforePublication() async throws {
        let store = store(), owned = try await store.create(title: "Saved", width: 10, height: 10)
        try addStagingWork(to: owned.resources)
        let baseline = owned.document, draft = try draft(baseline), destination = temporary.appendingPathComponent("Preview")
        let export = Task { try await store.exportPreview(draft, basedOn: baseline, to: destination) }
        try await waitForStagingDirectory(in: store.directory, prefix: ".import-")
        let saved = try await store.save(baseline, scene: baseline.scene, project: baseline.project, title: "Saved concurrently")
        do { _ = try await export.value; XCTFail("Published preview after its saved baseline changed during media staging") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let reopened = try await store.open(id: baseline.id)
        XCTAssertEqual(reopened.document, saved)
    }

    func testResourceCorruptionDuringFinalCopyRejectsPreviewBeforePublication() async throws {
        let store = store(), owned = try await store.create(title: "Saved", width: 10, height: 10)
        try addStagingWork(to: owned.resources)
        let session = try await store.acquireResourceSession(id: owned.document.id)
        defer { withExtendedLifetime(session) {} }
        let version = try await store.stageResource(id: owned.document.id, data: Data([1]), session: session)
        let draft = try draft(owned.document, overrides: ["resource.bin": version])
        let destination = temporary.appendingPathComponent("Preview")
        let export = Task { try await store.exportPreview(draft, basedOn: owned.document, to: destination) }
        try await waitForStagingDirectory(in: temporary, prefix: ".editor-export-")
        try Data([2]).write(to: owned.resources.deletingLastPathComponent().appendingPathComponent("Resources/" + version.id))
        do { _ = try await export.value; XCTFail("Published draft resource corrupted after its bytes were copied") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func addStagingWork(to resources: URL) throws {
        let payload = Data(repeating: 7, count: 4096)
        // Real regular-file IO keeps the media actor busy while the store actor can accept a save.
        for index in 0..<2048 { try payload.write(to: resources.appendingPathComponent("asset-\(index).bin")) }
    }

    private func waitForStagingDirectory(in directory: URL, prefix: String) async throws {
        while true {
            try Task.checkCancellation()
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(prefix) }) { return }
            await Task.yield()
        }
    }

    func testPackagePreviewExtractsLooseResourcesAndRemovesOnlyOwnedContainer() async throws {
        let source = temporary.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","title":"PKG","file":"scene.json"}"#.utf8).write(to: source.appendingPathComponent("project.json"))
        let package = ScenePackageReaderTests.package([("scene.json", Data(#"{"objects":[]}"#.utf8)), ("a.bin", Data([8]))])
        try package.write(to: source.appendingPathComponent("scene.pkg"))
        let store = store(), owned = try await store.importProject(root: source)
        let exported = try await store.exportPreview(draft(owned.document), basedOn: owned.document, to: temporary.appendingPathComponent("Preview"))
        XCTAssertEqual(try Data(contentsOf: exported.root.appendingPathComponent("a.bin")), Data([8]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.root.appendingPathComponent("scene.pkg").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("scene.pkg")), package)
        XCTAssertEqual(try Data(contentsOf: owned.resources.appendingPathComponent("scene.pkg")), package)
    }
}
