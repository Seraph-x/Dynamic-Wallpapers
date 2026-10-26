import AppKit
import XCTest
import WallpaperCore
import WallpaperEditorCore
import WebWallpaperBridge
@testable import EditorApp

// External CEF acknowledgements/window opening only. Snapshot validation and
// export use the actual owning controller and EditorProjectStore.
@MainActor private final class AuthoringPageFixture: EditorAuthoringPage {
    let view = NSView()
    var ready = true
    var closed = false
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onEditorDirty: ((Bool) -> Void)?
    var onEditorResource: (([String: Any]) -> Void)?
    var onEditorPreview: (() -> Void)?
    var document: [String: Any] = [:]
    var documentIdentity = "fixture-document"
    var payloads: [[String: Any]] = []
    var commands: [String] = []
    var invalidDraft = false
    var revealError: Error?
    var onThaw: (() -> Void)?
    var holdFreeze = false
    var pendingFreeze: (() -> Void)?
    var onFreeze: (() -> Void)?
    func start() {}
    func close(completion: @escaping (Error?) -> Void) { closed = true; completion(nil) }
    func requestEditorCommand(_ payload: [String: Any], completion: @escaping DWEditorCommandCompletion) {
        let type = payload["type"] as! String
        commands.append(type); payloads.append(payload)
        if type == "reveal-script", let revealError { completion(nil, revealError); return }
        if type == "freeze" && holdFreeze {
            pendingFreeze = { [document, documentIdentity] in completion(["document": document, "documentIdentity": documentIdentity, "dirty": true], nil) }
            onFreeze?(); return
        }
        if type == "snapshot" && invalidDraft { completion(["error": "Invalid visible draft"], nil); return }
        completion(type == "freeze" ? ["document": document, "documentIdentity": documentIdentity, "dirty": true] : ["document": document, "documentIdentity": documentIdentity], nil)
        if type == "thaw" { onThaw?() }
    }
}

@MainActor private final class PreviewWindowFixture: EditorPreviewWindow {
    var onClosed: (() -> Void)?
    var onError: ((Error, NSWindow?) -> Void)?
    var started = false
    var capturedScripts: EditorCapturedScriptSnapshot?
    var onSource: ((EditorCapturedScriptLink) -> Void)?
    func start() throws { started = true }
    func requestClose() async throws { onClosed?() }
}

@MainActor private final class PreviewCoordinatorFixture: EditorWindowCoordinator {
    let store: EditorProjectStore!
    let dataRoot: URL!
    var errors: [Error] = []
    var onError: (() -> Void)?
    init(root: URL) { dataRoot = root; store = EditorProjectStore(directory: root.appendingPathComponent("Projects")) }
    func show(_ error: Error, window: NSWindow?) { errors.append(error); onError?() }
    func retired(_ id: UUID) {}
}

@MainActor final class EditorPreviewRequestTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func testPreviewCallbackCapturesUnsavedDraftThroughOwnerWithoutSaving() async throws {
        let coordinator = PreviewCoordinatorFixture(root: temporary)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = AuthoringPageFixture(), preview = PreviewWindowFixture()
        var document = try EditorWindowController.browserDocument(owned.document)
        document["title"] = "Unsaved preview"
        document["scene"] = ["objects": [], "unsavedProbe": 42]
        let originalResource = Data([1, 2, 3]), stagedResource = Data([4, 5, 6])
        try originalResource.write(to: owned.resources.appendingPathComponent("probe.bin"))
        let version = try await coordinator.store.stageResource(id: owned.document.id, data: stagedResource)
        document["resourceOverrides"] = ["probe.bin": version.id]
        page.document = document
        let savedURL = owned.resources.deletingLastPathComponent().appendingPathComponent("workspace.json")
        let savedBytes = try Data(contentsOf: savedURL)
        let sceneBytes = try Data(contentsOf: owned.resources.appendingPathComponent(owned.document.sceneEntry))
        var exported: SceneProjectReference?
        let controller = try EditorWindowController(project: owned, coordinator: coordinator, page: page,
            makePreview: { project, title in
                exported = project
                XCTAssertEqual(title, "Unsaved preview")
                return preview
            })
        let ready = expectation(description: "Owner completed initial thaw")
        page.onThaw = { ready.fulfill() }; controller.start(); page.onReady?()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(controller.ready)
        page.commands.removeAll()
        let thawed = expectation(description: "Preview request completed and thawed")
        page.onThaw = { thawed.fulfill() }
        XCTAssertNotNil(page.onEditorPreview)
        page.onEditorPreview?()
        await fulfillment(of: [thawed], timeout: 2)
        XCTAssertEqual(page.commands, ["freeze", "snapshot", "thaw"])
        let project = try XCTUnwrap(exported)
        XCTAssertTrue(preview.started)
        let scene = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: project.entryURL)) as? [String: Any])
        XCTAssertEqual(scene["unsavedProbe"] as? Int, 42)
        XCTAssertEqual(try Data(contentsOf: project.root.appendingPathComponent("probe.bin")), stagedResource)
        XCTAssertEqual(try Data(contentsOf: owned.resources.appendingPathComponent("probe.bin")), originalResource)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: project.root.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertEqual(metadata["title"] as? String, "Unsaved preview")
        XCTAssertEqual(try Data(contentsOf: savedURL), savedBytes)
        XCTAssertEqual(try Data(contentsOf: owned.resources.appendingPathComponent(owned.document.sceneEntry)), sceneBytes)
        let reopened = try await coordinator.store.open(id: owned.document.id)
        XCTAssertEqual(reopened.document, owned.document)
        XCTAssertTrue(coordinator.errors.isEmpty)
        controller.window?.delegate = nil; controller.window?.close()
    }

    func testPreviewCallbackRejectsInvalidVisibleDraftAndThawsWithoutExporting() async throws {
        let coordinator = PreviewCoordinatorFixture(root: temporary)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = AuthoringPageFixture(); page.document = try EditorWindowController.browserDocument(owned.document)
        let savedURL = owned.resources.deletingLastPathComponent().appendingPathComponent("workspace.json")
        let savedBytes = try Data(contentsOf: savedURL)
        var creations = 0
        let controller = try EditorWindowController(project: owned, coordinator: coordinator, page: page,
            makePreview: { _, _ in creations += 1; return PreviewWindowFixture() })
        let ready = expectation(description: "Owner completed initial thaw")
        page.onThaw = { ready.fulfill() }; controller.start(); page.onReady?()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(controller.ready)
        page.commands.removeAll(); page.invalidDraft = true
        let failed = expectation(description: "Invalid draft surfaced by owning controller")
        coordinator.onError = { failed.fulfill() }; page.onThaw = nil
        XCTAssertNotNil(page.onEditorPreview)
        page.onEditorPreview?()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(page.commands, ["freeze", "snapshot", "thaw"])
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(coordinator.errors.first?.localizedDescription, "Invalid visible draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("Previews").path))
        XCTAssertEqual(try Data(contentsOf: savedURL), savedBytes)
        controller.window?.delegate = nil; controller.window?.close()
    }

    func testPreviewCallbackBeforeOwnerReadyReportsBusyWithoutExporting() async throws {
        let coordinator = PreviewCoordinatorFixture(root: temporary)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = AuthoringPageFixture()
        var creations = 0
        let controller = try EditorWindowController(project: owned, coordinator: coordinator, page: page,
            makePreview: { _, _ in creations += 1; return PreviewWindowFixture() })
        defer { controller.window?.delegate = nil; controller.window?.close() }
        XCTAssertFalse(controller.ready)
        page.onEditorPreview?()
        XCTAssertEqual(coordinator.errors.map(\.localizedDescription), [text("busy")])
        XCTAssertTrue(page.commands.isEmpty)
        XCTAssertEqual(creations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("Previews").path))
    }

    func testDuplicatePreviewCallbackWhileFreezePendingReportsBusyAndPreservesFirstRequest() async throws {
        let coordinator = PreviewCoordinatorFixture(root: temporary)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = AuthoringPageFixture(); page.document = try EditorWindowController.browserDocument(owned.document)
        var creations = 0
        let controller = try EditorWindowController(project: owned, coordinator: coordinator, page: page,
            makePreview: { _, _ in creations += 1; return PreviewWindowFixture() })
        defer { controller.window?.delegate = nil; controller.window?.close() }
        let ready = expectation(description: "Owner completed initial thaw")
        page.onThaw = { ready.fulfill() }; controller.start(); page.onReady?()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(controller.ready)
        page.commands.removeAll(); page.holdFreeze = true
        let frozen = expectation(description: "First request awaits external freeze acknowledgement")
        page.onFreeze = { frozen.fulfill() }
        page.onEditorPreview?()
        await fulfillment(of: [frozen], timeout: 2)
        XCTAssertTrue(controller.busy)
        page.onEditorPreview?()
        XCTAssertEqual(coordinator.errors.map(\.localizedDescription), [text("busy")])
        XCTAssertEqual(page.commands, ["freeze"])
        XCTAssertEqual(creations, 0)
        let thawed = expectation(description: "First request completes after acknowledgement")
        page.onThaw = { thawed.fulfill() }
        let reply = try XCTUnwrap(page.pendingFreeze); page.pendingFreeze = nil; reply()
        await fulfillment(of: [thawed], timeout: 2)
        XCTAssertEqual(page.commands, ["freeze", "snapshot", "thaw"])
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(coordinator.errors.count, 1)
    }

    func testCapturedSourceNavigationBelongsOnlyToItsOwnerAndIgnoresClosedPreview() async throws {
        let coordinator = PreviewCoordinatorFixture(root: temporary)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = AuthoringPageFixture(), otherPage = AuthoringPageFixture(), preview = PreviewWindowFixture()
        page.document = try EditorWindowController.browserDocument(owned.document)
        page.document["scene"] = ["objects": [["id": 1, "alpha": ["script": "// captured😀\r\nthrow Error()"]]]]
        page.documentIdentity = "owning-document"
        let controller = try EditorWindowController(project: owned, coordinator: coordinator, page: page, makePreview: { _, _ in preview })
        let other = try EditorWindowController(project: owned, coordinator: coordinator, page: otherPage, makePreview: { _, _ in PreviewWindowFixture() })
        defer { controller.window?.delegate = nil; controller.window?.close(); other.window?.delegate = nil; other.window?.close() }
        let ready = expectation(description: "Ready"); page.onThaw = { ready.fulfill() }
        page.onReady?(); await fulfillment(of: [ready], timeout: 2)
        let captured = expectation(description: "Captured"); page.onThaw = { captured.fulfill() }
        page.onEditorPreview?(); await fulfillment(of: [captured], timeout: 2)
        let snapshot = try XCTUnwrap(preview.capturedScripts)
        let issue = try EditorScriptDiagnostic(validated: ["layerId": 1, "layerName": "", "target": "alpha", "phase": "update", "message": "error", "line": 2, "count": 1])
        let link = try XCTUnwrap(snapshot.resolve(issue).link)
        XCTAssertEqual(link.documentIdentity, "owning-document"); XCTAssertEqual(link.source, "// captured😀\r\nthrow Error()")
        page.document["scene"] = ["objects": []]; page.commands.removeAll()
        let callback = try XCTUnwrap(preview.onSource)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        callback(link)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(page.commands, ["reveal-script"]); XCTAssertTrue(otherPage.commands.isEmpty)
        XCTAssertTrue(controller.window?.isVisible ?? false, "A successful source link must show its owning Editor")
        let payload = try XCTUnwrap(page.payloads.last?["link"] as? [String: Any])
        XCTAssertEqual(payload["source"] as? String, link.source)
        controller.window?.orderOut(nil); page.revealError = WallpaperError("Intentional navigation failure")
        let failed = expectation(description: "Failed navigation is surfaced")
        coordinator.onError = { failed.fulfill() }; callback(link)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(controller.window?.isVisible ?? true, "Failed navigation must not fabricate a successful focus change")
        XCTAssertEqual(coordinator.errors.last?.localizedDescription, "Intentional navigation failure")
        try await preview.requestClose(); callback(link)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(page.commands, ["reveal-script", "reveal-script"], "A closed preview cannot navigate its former owner")
    }

    func testPreviewNavigationDoesNotRetainReleasedOwner() async throws {
        let coordinator = PreviewCoordinatorFixture(root: temporary)
        let owned = try await coordinator.store.create(title: "Saved", width: 32, height: 32)
        let page = AuthoringPageFixture(), preview = PreviewWindowFixture()
        page.document = try EditorWindowController.browserDocument(owned.document)
        page.document["scene"] = ["objects": [["id": 1, "alpha": ["script": "captured"]]]]
        var owner: EditorWindowController? = try EditorWindowController(project: owned, coordinator: coordinator, page: page, makePreview: { _, _ in preview })
        weak var weakOwner = owner
        let ready = expectation(description: "Ready"); page.onThaw = { ready.fulfill() }
        page.onReady?(); await fulfillment(of: [ready], timeout: 2)
        let captured = expectation(description: "Captured"); page.onThaw = { captured.fulfill() }
        page.onEditorPreview?(); await fulfillment(of: [captured], timeout: 2)
        let issue = try EditorScriptDiagnostic(validated: ["layerId": 1, "layerName": "", "target": "alpha", "phase": "update", "message": "error", "line": NSNull(), "count": 1])
        let link = try XCTUnwrap(preview.capturedScripts?.resolve(issue).link)
        let callback = try XCTUnwrap(preview.onSource)
        owner?.window?.delegate = nil; owner?.window?.close(); owner = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(weakOwner); weakOwner = nil
        page.commands.removeAll(); callback(link)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(page.commands.isEmpty)
    }

}
