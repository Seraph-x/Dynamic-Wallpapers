import AppKit
import Darwin
import XCTest
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge
@testable import EditorApp

// Fixtures replace only external CEF transport and the user's modal choice.
// requestClose, save, workspace validation and filesystem storage remain real.
@MainActor private final class ScriptClosePageFixture: EditorAuthoringPage {
    let view = NSView()
    let ready = true
    private(set) var closed = false
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onEditorDirty: ((Bool) -> Void)?
    var onEditorResource: (([String: Any]) -> Void)?
    var onEditorPreview: (() -> Void)?
    let document: [String: Any]
    let source = "export function update(value){\r\n return (; // 雪\r\n}"
    private(set) var commands: [String] = []
    private(set) var frozen = false
    private(set) var sourceWhenThawed: String?
    private(set) var closedWhileFrozen = false
    var closeFailure: Error?
    var releaseOnClose = true
    var onDidClose: (() -> Void)?
    init(document: [String: Any]) { self.document = document }
    func start() {}
    func close(completion: @escaping (Error?) -> Void) {
        if let closeFailure { completion(closeFailure); return }
        closedWhileFrozen = frozen; closed = releaseOnClose; onDidClose?(); completion(nil)
    }
    func requestEditorCommand(_ payload: [String: Any], completion: @escaping DWEditorCommandCompletion) {
        let type = payload["type"] as! String
        commands.append(type)
        switch type {
        case "freeze":
            frozen = true
            // Only the uncommitted source is dirty; the canonical document is unchanged.
            completion(["document": document, "dirty": true], nil)
        case "snapshot": completion(["error": "SceneScript syntax error at line 2: Unexpected token"], nil)
        case "thaw":
            frozen = false; sourceWhenThawed = source
            completion([:], nil)
        default: completion(nil, WallpaperError("Unexpected close command: \(type)"))
        }
    }
}

@MainActor private final class ScriptCloseCoordinatorFixture: EditorWindowCoordinator {
    let store: EditorProjectStore!
    let dataRoot: URL!
    let response: NSApplication.ModalResponse
    private(set) var choices = 0
    private(set) var errors: [Error] = []
    private(set) var retiredIDs: [UUID] = []
    var onError: (() -> Void)?
    init(root: URL, response: NSApplication.ModalResponse) {
        dataRoot = root; store = EditorProjectStore(directory: root.appendingPathComponent("Projects"))
        self.response = response
    }
    func confirmClose() -> NSApplication.ModalResponse { choices += 1; return response }
    func show(_ error: Error, window: NSWindow?) { errors.append(error); onError?() }
    func retired(_ id: UUID) { retiredIDs.append(id) }
}

@MainActor final class EditorScriptCloseTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func fileBytes() throws -> [String: Data] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: temporary, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(temporary.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
    private func controller(_ owned: EditorOwnedProject, coordinator: ScriptCloseCoordinatorFixture,
                            page: ScriptClosePageFixture) async throws -> EditorWindowController {
        try EditorWindowController(project: owned, resourceSession: try await coordinator.store.acquireResourceSession(id: owned.document.id), coordinator: coordinator, page: page, makePreview: { _, _ in
            XCTFail("Closing a source draft must not create a preview")
            fatalError("Unexpected preview creation")
        })
    }

    func testCloseDecisionDispatchesThroughCoordinatorUIBoundary() {
        let fixture = ScriptCloseCoordinatorFixture(root: temporary, response: .alertThirdButtonReturn)
        let externalUI: any EditorWindowCoordinator = fixture
        XCTAssertEqual(externalUI.confirmClose(), .alertThirdButtonReturn)
        XCTAssertEqual(fixture.choices, 1)
    }

    func testCancelDraftOnlyDirtyCloseThawsAndPreservesSourceAndSavedBytes() async throws {
        let coordinator = ScriptCloseCoordinatorFixture(root: temporary, response: .alertThirdButtonReturn)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = ScriptClosePageFixture(document: try EditorWindowController.browserDocument(owned.document))
        let controller = try await controller(owned, coordinator: coordinator, page: page)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let savedBytes = try fileBytes(), source = page.source
        XCTAssertFalse(controller.window!.isDocumentEdited)
        let closed = try await controller.requestClose()
        XCTAssertFalse(closed)
        let collection = try await coordinator.store.collectUnusedResources(id: owned.document.id)
        XCTAssertTrue(collection.activeSession)
        XCTAssertEqual(coordinator.choices, 1)
        XCTAssertEqual(page.commands, ["freeze", "thaw"])
        XCTAssertFalse(page.frozen); XCTAssertFalse(page.closed)
        XCTAssertEqual(page.sourceWhenThawed, source); XCTAssertEqual(page.source, source)
        XCTAssertTrue(coordinator.errors.isEmpty); XCTAssertTrue(coordinator.retiredIDs.isEmpty)
        XCTAssertEqual(try fileBytes(), savedBytes)
        let reopened = try await coordinator.store.open(id: owned.document.id)
        XCTAssertEqual(reopened.document, owned.document)
    }

    func testSaveInvalidDraftOnlyDirtyCloseShowsSyntaxErrorAndThawsWithoutWriting() async throws {
        let coordinator = ScriptCloseCoordinatorFixture(root: temporary, response: .alertFirstButtonReturn)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = ScriptClosePageFixture(document: try EditorWindowController.browserDocument(owned.document))
        let controller = try await controller(owned, coordinator: coordinator, page: page)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let savedBytes = try fileBytes(), source = page.source
        let failed = expectation(description: "Window close reports the actual source error after thaw")
        coordinator.onError = { failed.fulfill() }
        // The window delegate invokes requestClose and owns presenting its thrown error.
        XCTAssertFalse(controller.windowShouldClose(try XCTUnwrap(controller.window)))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(coordinator.choices, 1)
        XCTAssertEqual(page.commands, ["freeze", "freeze", "snapshot", "thaw"])
        XCTAssertEqual(coordinator.errors.map(\.localizedDescription), ["SceneScript syntax error at line 2: Unexpected token"])
        XCTAssertFalse(page.frozen); XCTAssertFalse(page.closed)
        XCTAssertEqual(page.sourceWhenThawed, source); XCTAssertEqual(page.source, source)
        XCTAssertTrue(coordinator.retiredIDs.isEmpty)
        XCTAssertEqual(try fileBytes(), savedBytes)
        let reopened = try await coordinator.store.open(id: owned.document.id)
        XCTAssertEqual(reopened.document, owned.document)
    }

    func testDiscardInvalidDraftOnlyDirtyCloseRetiresWithoutSnapshotOrWrite() async throws {
        let coordinator = ScriptCloseCoordinatorFixture(root: temporary, response: .alertSecondButtonReturn)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = ScriptClosePageFixture(document: try EditorWindowController.browserDocument(owned.document))
        let controller = try await controller(owned, coordinator: coordinator, page: page)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let savedBytes = try fileBytes()
        let closed = try await controller.requestClose()
        XCTAssertTrue(closed)
        XCTAssertEqual(coordinator.choices, 1)
        XCTAssertEqual(page.commands, ["freeze"])
        XCTAssertTrue(page.closed); XCTAssertTrue(page.closedWhileFrozen)
        XCTAssertEqual(coordinator.retiredIDs, [owned.document.id]); XCTAssertTrue(coordinator.errors.isEmpty)
        XCTAssertEqual(try fileBytes(), savedBytes)
        let collection = try await coordinator.store.collectUnusedResources(id: owned.document.id)
        XCTAssertFalse(collection.activeSession)
        let reopened = try await coordinator.store.open(id: owned.document.id)
        XCTAssertEqual(reopened.document, owned.document)
    }
    func testCloseFailureRetainsResourceSessionAndDoesNotRetireWindow() async throws {
        let coordinator = ScriptCloseCoordinatorFixture(root: temporary, response: .alertSecondButtonReturn)
        let owned = try await coordinator.store.create(title: "Close failure", width: 32, height: 32)
        let page = ScriptClosePageFixture(document: try EditorWindowController.browserDocument(owned.document))
        page.closeFailure = WallpaperError("Browser resources remain owned")
        let controller = try await controller(owned, coordinator: coordinator, page: page)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        do { _ = try await controller.requestClose(); XCTFail("Accepted failed browser close") } catch {}
        let collection = try await coordinator.store.collectUnusedResources(id: owned.document.id)
        XCTAssertTrue(collection.activeSession)
        XCTAssertFalse(page.closed)
        XCTAssertTrue(coordinator.retiredIDs.isEmpty)
    }

    func testSuccessfulBrowserCloseWaitsForPendingNativeResourceStageBeforeReleasingSession() async throws {
        let coordinator = ScriptCloseCoordinatorFixture(root: temporary, response: .alertSecondButtonReturn)
        let owned = try await coordinator.store.create(title: "Pending resource", width: 32, height: 32)
        let page = ScriptClosePageFixture(document: try EditorWindowController.browserDocument(owned.document))
        let controller = try await controller(owned, coordinator: coordinator, page: page)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let workspaceLock = owned.resources.deletingLastPathComponent().appendingPathComponent(".workspace-lock")
        let descriptor = Darwin.open(workspaceLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        page.onEditorResource?(["id": "pending-stage", "action": "stage", "data": "AQI="])
        let browserClosed = expectation(description: "Browser resource release completed")
        page.onDidClose = { browserClosed.fulfill() }
        let close = Task { try await controller.requestClose() }
        await fulfillment(of: [browserClosed], timeout: 2)
        let observer = EditorProjectStore(directory: coordinator.store.directory)
        let pending = try await observer.collectUnusedResources(id: owned.document.id)
        XCTAssertTrue(pending.activeSession, "Native resource jobs must retain the lease after the browser closes")
        XCTAssertTrue(coordinator.retiredIDs.isEmpty)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let didClose = try await close.value
        XCTAssertTrue(didClose)
        let collected = try await observer.collectUnusedResources(id: owned.document.id)
        XCTAssertFalse(collected.activeSession)
        XCTAssertEqual(collected.removedVersions.count, 1)
        XCTAssertEqual(collected.reclaimedBytes, 2)
    }

    func testSuccessfulCallbackWithoutActualPageReleaseRetainsResourceSession() async throws {
        let coordinator = ScriptCloseCoordinatorFixture(root: temporary, response: .alertSecondButtonReturn)
        let owned = try await coordinator.store.create(title: "Unreleased browser", width: 32, height: 32)
        let page = ScriptClosePageFixture(document: try EditorWindowController.browserDocument(owned.document))
        page.releaseOnClose = false
        let controller = try await controller(owned, coordinator: coordinator, page: page)
        defer { controller.window?.delegate = nil; controller.window?.close() }
        do { _ = try await controller.requestClose(); XCTFail("Released session without actual browser resource release") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not release its resources")) }
        let collection = try await coordinator.store.collectUnusedResources(id: owned.document.id)
        XCTAssertTrue(collection.activeSession)
        XCTAssertFalse(page.closed)
        XCTAssertTrue(coordinator.retiredIDs.isEmpty)
    }

}
