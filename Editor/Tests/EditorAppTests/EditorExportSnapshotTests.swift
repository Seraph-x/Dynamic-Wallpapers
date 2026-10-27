import AppKit
import XCTest
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge
@testable import EditorApp

// CEF transport is external. The owner saves and exports through the real store;
// package replies use the checked-in fixture, not a simulated package encoder.
@MainActor private final class ExportSnapshotPageFixture: EditorAuthoringPage {
    let view = NSView()
    let ready = true
    var closed = false
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onEditorDirty: ((Bool) -> Void)?
    var onEditorResource: (([String: Any]) -> Void)?
    var onEditorPreview: (() -> Void)?
    let document: [String: Any]
    var package: Data
    var invalidSource = false
    var packageError: String?
    var thawError: String?
    var holdPackage = false
    var pendingPackage: (() -> Void)?
    var onPackage: (() -> Void)?
    var onThaw: (() -> Void)?
    private(set) var frozen = false
    private(set) var commands: [String] = []
    private(set) var packageWasFrozen = false
    private(set) var packagePaths: [String] = []
    private(set) var sourceDraft = "captured source S1"
    private(set) var packageSource: String?
    init(document: [String: Any], package: Data) { self.document = document; self.package = package }
    func start() {}
    func close(completion: @escaping (Error?) -> Void) { closed = true; completion(nil) }
    func requestEditorCommand(_ payload: [String: Any], completion: @escaping DWEditorCommandCompletion) {
        let type = payload["type"] as! String
        commands.append(type)
        switch type {
        case "freeze": frozen = true; completion(["document": document, "dirty": true], nil)
        case "snapshot":
            completion(invalidSource ? ["error": "Invalid SceneScript draft at line 2"] : ["document": document], nil)
        case "mark-saved": completion([:], nil)
        case "export-pkg":
            packageWasFrozen = frozen; packageSource = sourceDraft
            packagePaths = payload["paths"] as? [String] ?? []
            let reply = { [package, packageError] in
                completion(packageError.map { ["error": $0] } ?? ["pkg": package.base64EncodedString()], nil)
            }
            if holdPackage { pendingPackage = reply; onPackage?() } else { reply() }
        case "thaw":
            if let thawError { completion(["error": thawError], nil); return }
            frozen = false
            // A newly typed draft becomes possible only after the thaw command.
            sourceDraft = "new source S2"
            onThaw?(); completion([:], nil)
        default: completion(nil, WallpaperError("Unexpected export command: \(type)"))
        }
    }
}

@MainActor private final class ExportSnapshotCoordinatorFixture: EditorWindowCoordinator {
    let store: EditorProjectStore!
    let dataRoot: URL!
    init(root: URL) { dataRoot = root; store = EditorProjectStore(directory: root.appendingPathComponent("Projects")) }
    func show(_ error: Error, window: NSWindow?) { XCTFail("Unexpected external alert: \(error)") }
    func retired(_ id: UUID) { XCTFail("Export must not retire its authoring owner") }
}

@MainActor final class EditorExportSnapshotTests: XCTestCase {
    private var temporary: URL!
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/SceneAnimatedPackage")
    }
    override func setUpWithError() throws {
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func session() async throws -> (ExportSnapshotCoordinatorFixture, EditorOwnedProject, ExportSnapshotPageFixture, EditorWindowController) {
        let coordinator = ExportSnapshotCoordinatorFixture(root: temporary)
        let owned = try await coordinator.store.importProject(root: fixture)
        let page = ExportSnapshotPageFixture(document: try EditorWindowController.browserDocument(owned.document),
            package: try Data(contentsOf: fixture.appendingPathComponent("scene.pkg")))
        let controller = try EditorWindowController(project: owned, resourceSession: try await coordinator.store.acquireResourceSession(id: owned.document.id), coordinator: coordinator, page: page, makePreview: { _, _ in
            XCTFail("Export must not create a preview"); fatalError("Unexpected preview")
        })
        return (coordinator, owned, page, controller)
    }
    private func close(_ controller: EditorWindowController) { controller.window?.delegate = nil; controller.window?.close() }
    private func assertNoStaging(_ coordinator: ExportSnapshotCoordinatorFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for root in [temporary!, coordinator.store.directory] {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(names.contains { $0.hasPrefix(".editor-") || $0.hasPrefix(".import-") }, file: file, line: line)
        }
    }

    func testLooseExportPublishesSavedSnapshotBeforeThawAllowsNewSource() async throws {
        let (coordinator, owned, page, controller) = try await session()
        defer { close(controller) }
        let destination = temporary.appendingPathComponent("Loose")
        var publishedAtThaw = false
        page.onThaw = { publishedAtThaw = FileManager.default.fileExists(atPath: destination.appendingPathComponent("scene.json").path) }
        try await controller.exportSnapshot(package: false, to: destination)
        XCTAssertEqual(page.commands, ["freeze", "snapshot", "mark-saved", "thaw"])
        XCTAssertTrue(publishedAtThaw); XCTAssertFalse(page.frozen)
        XCTAssertEqual(page.sourceDraft, "new source S2")
        let saved = try await coordinator.store.open(id: owned.document.id)
        XCTAssertEqual(saved.document.revision, owned.document.revision + 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("scene.json")), saved.document.scene)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("scene.pkg").path))
        try assertNoStaging(coordinator)
    }

    func testPackageExportRemainsFrozenAcrossBrowserReplyAndPublishesCapturedRevision() async throws {
        let (coordinator, owned, page, controller) = try await session()
        defer { close(controller) }
        let destination = temporary.appendingPathComponent("Package")
        let requested = expectation(description: "Frozen browser package request is pending")
        page.holdPackage = true; page.onPackage = { requested.fulfill() }
        var publishedAtThaw = false
        page.onThaw = { publishedAtThaw = FileManager.default.fileExists(atPath: destination.appendingPathComponent("scene.pkg").path) }
        let operation = Task { try await controller.exportSnapshot(package: true, to: destination) }
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertTrue(page.frozen); XCTAssertTrue(page.packageWasFrozen)
        XCTAssertEqual(page.packageSource, "captured source S1")
        XCTAssertEqual(page.commands, ["freeze", "snapshot", "mark-saved", "export-pkg"])
        XCTAssertTrue(page.packagePaths.contains("scene.json")); XCTAssertTrue(page.packagePaths.contains("scene.pkg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let reply = try XCTUnwrap(page.pendingPackage); page.pendingPackage = nil; reply()
        try await operation.value
        XCTAssertTrue(publishedAtThaw); XCTAssertFalse(page.frozen)
        XCTAssertEqual(page.commands.last, "thaw"); XCTAssertEqual(page.sourceDraft, "new source S2")
        let exported = try Data(contentsOf: destination.appendingPathComponent("scene.pkg"))
        XCTAssertEqual(exported, page.package)
        let saved = try await coordinator.store.open(id: owned.document.id)
        let packagedScene = try JSONSerialization.jsonObject(with: ScenePackageReader(data: exported).read("scene.json")) as! NSDictionary
        XCTAssertEqual(packagedScene, try JSONSerialization.jsonObject(with: saved.document.scene) as! NSDictionary)
        try assertNoStaging(coordinator)
    }

    func testInvalidDraftSaveThawsOnceAndNeverStartsExportOrWritesWorkspace() async throws {
        let (coordinator, owned, page, controller) = try await session()
        defer { close(controller) }
        let manifest = owned.resources.deletingLastPathComponent().appendingPathComponent("workspace.json")
        let original = try Data(contentsOf: manifest), destination = temporary.appendingPathComponent("Invalid")
        page.invalidSource = true
        do { try await controller.exportSnapshot(package: true, to: destination); XCTFail("Exported invalid draft") }
        catch { XCTAssertEqual(error.localizedDescription, "Invalid SceneScript draft at line 2") }
        XCTAssertEqual(page.commands, ["freeze", "snapshot", "thaw"])
        XCTAssertFalse(page.frozen); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        try assertNoStaging(coordinator)
    }

    func testPackageTransportFailureThawsAndPreservesActualErrorWithoutOutput() async throws {
        let (coordinator, _, page, controller) = try await session()
        defer { close(controller) }
        let destination = temporary.appendingPathComponent("Transport")
        page.packageError = "Browser package compilation failed"
        do { try await controller.exportSnapshot(package: true, to: destination); XCTFail("Ignored browser error") }
        catch { XCTAssertEqual(error.localizedDescription, "Browser package compilation failed") }
        XCTAssertTrue(page.packageWasFrozen); XCTAssertFalse(page.frozen)
        XCTAssertEqual(page.commands, ["freeze", "snapshot", "mark-saved", "export-pkg", "thaw"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStaging(coordinator)
    }

    func testInvalidPackageBytesSurfaceRealParserFailureAndThawWithoutStaging() async throws {
        let (coordinator, _, page, controller) = try await session()
        defer { close(controller) }
        let destination = temporary.appendingPathComponent("InvalidPackage")
        page.package = Data([1])
        var expected: String?
        do { _ = try ScenePackageReader(data: page.package); XCTFail("Fixture unexpectedly parsed") } catch { expected = error.localizedDescription }
        do { try await controller.exportSnapshot(package: true, to: destination); XCTFail("Exported invalid bytes") }
        catch { XCTAssertEqual(error.localizedDescription, expected) }
        XCTAssertTrue(page.packageWasFrozen); XCTAssertFalse(page.frozen)
        XCTAssertEqual(page.commands.last, "thaw")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStaging(coordinator)
    }

    func testOccupiedPackageDestinationCleansRealStagingAndThawsWithoutOverwriting() async throws {
        let (coordinator, _, page, controller) = try await session()
        defer { close(controller) }
        let destination = temporary.appendingPathComponent("Occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.bin"), bytes = Data([1,2,3])
        try bytes.write(to: marker)
        do { try await controller.exportSnapshot(package: true, to: destination); XCTFail("Overwrote destination") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未覆盖已有目标")) }
        XCTAssertFalse(page.frozen); XCTAssertEqual(try Data(contentsOf: marker), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["keep.bin"])
        try assertNoStaging(coordinator)
    }

    func testPackageFailureAndThawFailureRemainIndividuallyObservable() async throws {
        let (coordinator, _, page, controller) = try await session()
        defer { close(controller) }
        page.packageError = "Browser package compilation failed"; page.thawError = "Authoring thaw failed"
        let destination = temporary.appendingPathComponent("FailedThaw")
        do { try await controller.exportSnapshot(package: true, to: destination); XCTFail("Suppressed failures") }
        catch {
            let group = try XCTUnwrap(error as? WallpaperErrorGroup)
            XCTAssertEqual(group.errors.map(\.localizedDescription), ["Browser package compilation failed", "Authoring thaw failed"])
        }
        XCTAssertTrue(page.frozen); XCTAssertEqual(page.commands.filter { $0 == "thaw" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStaging(coordinator)
    }
}
