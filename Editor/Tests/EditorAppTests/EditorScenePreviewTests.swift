import AppKit
import XCTest
import WallpaperCore
import WallpaperAudioSpectrum
import WallpaperEditorCore
import WebWallpaperBridge
@testable import EditorApp

// External native-page fixture: controls acknowledgements/failures, never renders
// or supplies pixel success. Real CEF playback is a separate native acceptance.
@MainActor final class PreviewPageFixture: EditorScenePreviewPage {
    let view = NSView()
    let origin = UUID().uuidString
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onDiagnostic: (([String: Any]) -> Void)?
    var onSceneScriptIssue: (([String: Any]) -> Void)?
    var onSceneScriptRawIssue: ((String) -> Void)?
    var startError: Error?
    var closeError: Error?
    var playError: Error?
    var propertyRequests: [NSDictionary] = []
    var propertyError: Error?
    var holdProperties = false
    var propertyReply: CheckedContinuation<Void, Error>?
    func setUserProperties(_ values: [String: Any]) async throws {
        try await setUserPropertyData(JSONSerialization.data(withJSONObject: values))
    }
    func setUserPropertyData(_ data: Data) async throws {
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        propertyRequests.append(values)
        if holdProperties { try await withCheckedThrowingContinuation { propertyReply = $0 } }
        if let propertyError { throw propertyError }
    }
    var closed = false
    var playingRequests: [Bool] = []
    var holdPlaying = false
    var playReply: CheckedContinuation<Void, Error>?
    var onPlay: (() -> Void)?
    var onClose: (() -> Void)?
    var holdClose = false
    var closeReply: CheckedContinuation<Void, Error>?
    var spectra: [AudioSpectrum] = []
    var spectrumError: Error?
    func setSpectrum(_ value: AudioSpectrum) throws {
        if let spectrumError { throw spectrumError }; spectra.append(value)
    }
    func start() throws { if let startError { throw startError } }
    func setPlaying(_ value: Bool) async throws {
        playingRequests.append(value); onPlay?()
        if holdPlaying { try await withCheckedThrowingContinuation { playReply = $0 } }
        if let playError { throw playError }
    }
    func close() async throws {
        onClose?()
        if holdClose { try await withCheckedThrowingContinuation { closeReply = $0 } }
        if let closeError { throw closeError }
        closed = true
    }
}

@MainActor final class EditorScenePreviewTests: XCTestCase {
    private let failure = WallpaperError("Intentional native page failure")
    private func ready(_ page: PreviewPageFixture, _ session: EditorScenePreviewSession) async {
        page.onReady?()
        for _ in 0..<50 { if session.state != .loading { return }; await Task.yield() }
        XCTFail("Native play acknowledgement did not finish")
    }

    func testReadyWaitsForRealPlayAcknowledgement() async throws {
        let page = PreviewPageFixture(); page.holdPlaying = true
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {})
        try session.start(); page.onReady?()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(page.playingRequests, [true], "Ready must issue the native play command")
        XCTAssertEqual(session.state, .loading, "Ready alone cannot claim acknowledged playback")
        page.playReply?.resume()
        for _ in 0..<10 { await Task.yield() }
        try await session.close()
    }

    func testAcknowledgedPageIsReleasedAfterClose() async throws {
        var candidate: PreviewPageFixture? = PreviewPageFixture()
        weak var released = candidate
        let session = EditorScenePreviewSession(makePage: { try XCTUnwrap(candidate) }, cleanup: {})
        try session.start(); await ready(try XCTUnwrap(candidate), session)
        candidate = nil
        try await session.close()
        XCTAssertNil(released, "Ready callback must not retain its own page after acknowledged close")
    }

    func testPendingOldAcknowledgementReleasesPageAfterItCompletes() async throws {
        var candidate: PreviewPageFixture? = PreviewPageFixture()
        candidate?.holdPlaying = true; weak var released = candidate
        let session = EditorScenePreviewSession(makePage: { try XCTUnwrap(candidate) }, cleanup: {})
        try session.start(); candidate?.onReady?()
        for _ in 0..<20 { await Task.yield() }
        let reply = candidate?.playReply; candidate?.playReply = nil
        candidate = nil; try await session.close()
        reply?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(released, "Obsolete acknowledgement task must release its old page when complete")
        XCTAssertEqual(session.state, .closed)
    }

    func testReadinessPlaybackAndCloseAreAcknowledged() async throws {
        let page = PreviewPageFixture()
        var cleanups = 0
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: { cleanups += 1 })
        try session.start()
        XCTAssertEqual(session.state, .loading)
        XCTAssertTrue(session.view === page.view)
        await ready(page, session)
        XCTAssertEqual(session.state, .playing)
        try await session.setPlaying(false)
        XCTAssertEqual(session.state, .paused)
        try await session.setPlaying(true)
        XCTAssertEqual(page.playingRequests, [true, false, true])
        XCTAssertEqual(session.state, .playing)
        try await session.close()
        XCTAssertTrue(page.closed)
        XCTAssertEqual(cleanups, 1)
        XCTAssertNil(session.view)
        XCTAssertEqual(session.state, .closed)
        try await session.close()
        XCTAssertEqual(cleanups, 1)
    }

    func testRestartWaitsForReleaseAndRejectsOldCallbacks() async throws {
        let first = PreviewPageFixture(), second = PreviewPageFixture()
        var pages = [first, second], creations = 0, cleanups = 0
        let session = EditorScenePreviewSession(makePage: { creations += 1; return pages.removeFirst() }, cleanup: { cleanups += 1 })
        try session.start(); await ready(first, session)
        let oldReady = first.onReady, oldError = first.onError
        let released = expectation(description: "Old page release requested")
        first.holdClose = true; first.onClose = { released.fulfill() }
        let restart = Task { try await session.restart() }
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(creations, 1, "Replacement cannot start while old page is alive")
        XCTAssertTrue(session.busy)
        first.closeReply?.resume(); try await restart.value
        XCTAssertTrue(first.closed); XCTAssertEqual(creations, 2)
        XCTAssertEqual(cleanups, 0, "Restart must retain its captured snapshot")
        XCTAssertEqual(session.state, .loading)
        oldReady?(); oldError?(failure)
        XCTAssertEqual(session.state, .loading); XCTAssertNil(session.failure)
        await ready(second, session); XCTAssertEqual(session.state, .playing)
        try await session.close(); XCTAssertEqual(cleanups, 1)
    }

    func testLoadingCanCloseAndLateReadyCannotResurrectIt() async throws {
        let page = PreviewPageFixture()
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {})
        try session.start(); let ready = page.onReady, error = page.onError
        try await session.close(); ready?(); error?(failure)
        XCTAssertEqual(session.state, .closed); XCTAssertNil(session.failure)
    }

    func testFactoryAndStartFailuresRetainRootUntilExplicitClose() async throws {
        var cleanups = 0
        let factoryFailed = EditorScenePreviewSession(makePage: { throw self.failure }, cleanup: { cleanups += 1 })
        XCTAssertThrowsError(try factoryFailed.start())
        XCTAssertEqual(factoryFailed.state, .failed); XCTAssertEqual(cleanups, 0)
        try await factoryFailed.close(); XCTAssertEqual(cleanups, 1)
        let page = PreviewPageFixture(); page.startError = failure
        let startFailed = EditorScenePreviewSession(makePage: { page }, cleanup: { cleanups += 1 })
        XCTAssertThrowsError(try startFailed.start())
        XCTAssertFalse(page.closed); XCTAssertNotNil(startFailed.view)
        try await startFailed.close(); XCTAssertTrue(page.closed); XCTAssertEqual(cleanups, 2)
    }

    func testCloseFailureKeepsPageAndRootForRetry() async throws {
        let page = PreviewPageFixture(); var cleanups = 0
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: { cleanups += 1 })
        try session.start(); await ready(page, session); page.closeError = failure
        do { try await session.close(); XCTFail("Close failure was hidden") } catch {}
        XCTAssertEqual(session.state, .failed); XCTAssertNotNil(session.view)
        XCTAssertEqual(cleanups, 0); XCTAssertFalse(page.closed)
        page.closeError = nil; try await session.close()
        XCTAssertEqual(cleanups, 1); XCTAssertEqual(session.state, .closed)
    }

    func testFailedRestartAcquisitionAndStartKeepSnapshotOwnership() async throws {
        let first = PreviewPageFixture(), replacement = PreviewPageFixture()
        var attempts = 0, cleanups = 0
        let session = EditorScenePreviewSession(makePage: {
            attempts += 1
            if attempts == 1 { return first }
            if attempts == 2 { throw self.failure }
            return replacement
        }, cleanup: { cleanups += 1 })
        try session.start(); await ready(first, session)
        do { try await session.restart(); XCTFail("Restart factory failure was hidden") } catch {}
        XCTAssertTrue(first.closed); XCTAssertNil(session.view)
        XCTAssertEqual(session.state, .failed); XCTAssertEqual(cleanups, 0)
        replacement.startError = failure
        do { try await session.restart(); XCTFail("Restart start failure was hidden") } catch {}
        XCTAssertFalse(replacement.closed); XCTAssertNotNil(session.view)
        XCTAssertEqual(cleanups, 0)
        try await session.close(); XCTAssertTrue(replacement.closed)
        XCTAssertEqual(cleanups, 1)
    }

    func testCleanupFailureRetriesAfterPageReleaseWithoutClosingItAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = PreviewPageFixture(); var attempts = 0, closes = 0
        page.onClose = { closes += 1 }
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {
            XCTAssertTrue(page.closed)
            attempts += 1
            if attempts == 1 { throw self.failure }
            try FileManager.default.removeItem(at: root)
        })
        try session.start()
        do { try await session.close(); XCTFail("Cleanup failure was hidden") } catch {}
        XCTAssertEqual(session.state, .failed); XCTAssertNil(session.view)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        try await session.close()
        XCTAssertEqual(attempts, 2); XCTAssertEqual(closes, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testBusyCloseCannotCreateOrDeleteAnotherGeneration() async throws {
        let page = PreviewPageFixture(); var creations = 0, cleanups = 0
        let session = EditorScenePreviewSession(makePage: { creations += 1; return page }, cleanup: { cleanups += 1 })
        try session.start(); page.holdClose = true
        let started = expectation(description: "Close began"); page.onClose = { started.fulfill() }
        let closing = Task { try await session.close() }; await fulfillment(of: [started], timeout: 2)
        do { try await session.restart(); XCTFail("Concurrent restart accepted") } catch {}
        do { try await session.setPlaying(false); XCTFail("Concurrent playback accepted") } catch {}
        XCTAssertEqual(creations, 1); XCTAssertEqual(cleanups, 0)
        page.closeReply?.resume(); try await closing.value
        XCTAssertEqual(cleanups, 1)
    }

    func testPlaybackFailureAndAsynchronousRuntimeErrorStayVisible() async throws {
        let page = PreviewPageFixture()
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {})
        try session.start(); await ready(page, session); page.playError = failure
        do { try await session.setPlaying(false); XCTFail("Playback failure hidden") } catch {}
        XCTAssertEqual(session.state, .failed); XCTAssertNotNil(session.failure)
        try await session.close()
        let other = PreviewPageFixture()
        let runtimeError = EditorScenePreviewSession(makePage: { other }, cleanup: {})
        try runtimeError.start(); other.onError?(failure)
        XCTAssertEqual(runtimeError.state, .failed); XCTAssertNotNil(runtimeError.failure)
        other.onReady?(); XCTAssertEqual(runtimeError.state, .failed)
        try await runtimeError.close()
    }

    func testRuntimeWarningsAreVisibleAndOldGenerationCannotReplaceNewDiagnostics() async throws {
        let first = PreviewPageFixture(), second = PreviewPageFixture(); var pages = [first, second]
        let session = EditorScenePreviewSession(makePage: { pages.removeFirst() }, cleanup: {})
        try session.start(); await ready(first, session)
        first.onDiagnostic?(["level": "warn", "message": "Script update failed", "source": "fixture.js", "line": 7])
        XCTAssertEqual(session.diagnostic?["message"] as? String, "Script update failed")
        XCTAssertEqual(session.state, .playing, "Warnings must not fabricate a fatal failure")
        let stale = first.onDiagnostic
        try await session.restart(); XCTAssertNil(session.diagnostic)
        second.onDiagnostic?(["level": "warn", "message": "New source warning"])
        stale?(["level": "warn", "message": "Obsolete warning"])
        XCTAssertEqual(session.diagnostic?["message"] as? String, "New source warning")
        try await session.close()
    }

    func testRetainedIssuesUseActualCountsAndRestartRejectsOldDelivery() async throws {
        let first = PreviewPageFixture(), second = PreviewPageFixture(); var pages = [first, second]
        let session = EditorScenePreviewSession(makePage: { pages.removeFirst() }, cleanup: {})
        try session.start()
        let record: [String: Any] = ["layerId": 1, "layerName": "", "target": "alpha", "phase": "update", "message": "failure", "line": NSNull(), "count": 1]
        first.onSceneScriptIssue?(record)
        first.onDiagnostic?(["message": "generic one"]); first.onDiagnostic?(["message": "generic two"])
        var refreshed = record; refreshed["count"] = 8; first.onSceneScriptIssue?(refreshed)
        XCTAssertEqual(session.scriptIssues.count, 1); XCTAssertEqual(session.scriptIssues.first?.count, 8)
        XCTAssertEqual(session.consoleDiagnostics.count, 2)
        let old = first.onSceneScriptIssue, oldConsole = first.onDiagnostic
        try await session.restart()
        XCTAssertTrue(session.scriptIssues.isEmpty); XCTAssertTrue(session.consoleDiagnostics.isEmpty)
        old?(refreshed); oldConsole?(["message": "stale"])
        XCTAssertTrue(session.scriptIssues.isEmpty); XCTAssertTrue(session.consoleDiagnostics.isEmpty)
        second.onSceneScriptIssue?(record)
        XCTAssertEqual(session.scriptIssues.first?.count, 1)
        try await session.close(); old?(refreshed)
        XCTAssertTrue(session.scriptIssues.isEmpty)
    }

    func testFailedClosePreservesIssuesAndInvalidatesCallbacksUntilCleanupSucceeds() async throws {
        let page = PreviewPageFixture(); var cleanups = 0
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {
            cleanups += 1
            if cleanups == 1 { throw self.failure }
        })
        try session.start()
        let record: [String: Any] = ["layerId": NSNull(), "layerName": "", "target": "general.zoom", "phase": "update", "message": "retained", "line": NSNull(), "count": 7]
        page.onSceneScriptIssue?(record); page.onDiagnostic?(["message": "generic"])
        let stale = page.onSceneScriptIssue
        page.closeError = failure
        do { try await session.close(); XCTFail("Expected close failure") } catch {}
        XCTAssertEqual(cleanups, 0); XCTAssertEqual(session.scriptIssues.first?.count, 7)
        var changed = record; changed["count"] = 100; stale?(changed)
        XCTAssertEqual(session.scriptIssues.first?.count, 7)
        page.closeError = nil
        do { try await session.close(); XCTFail("Expected cleanup failure") } catch {}
        XCTAssertNil(session.view); XCTAssertEqual(session.consoleDiagnostics.count, 1)
        XCTAssertEqual(session.scriptIssues.first?.count, 7)
        try await session.close()
        XCTAssertEqual(cleanups, 2); XCTAssertTrue(session.scriptIssues.isEmpty)
    }

    func testRawJSONReportsPreserveExactBytesAndDistinctCountSnapshots() async throws {
        let page = PreviewPageFixture()
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {})
        try session.start()
        let first = #"{"layerId":1,"layerName":"","target":"alpha","phase":"update","message":"\ud83d","line":2,"count":1}"#
        let refreshed = first.replacingOccurrences(of: #""count":1"#, with: #""count":3"#)
        page.onSceneScriptRawIssue?(first); page.onSceneScriptRawIssue?(first)
        page.onSceneScriptRawIssue?(refreshed)
        let composed = #"{"message":"é","raw":"\ud83d"}"#
        let decomposed = composed.replacingOccurrences(of: "é", with: "e\u{301}")
        page.onSceneScriptRawIssue?(composed); page.onSceneScriptRawIssue?(decomposed)
        XCTAssertEqual(session.rawJSONReports.count, 4)
        XCTAssertEqual(session.rawJSONReports.map { Data($0.utf8) }, [first, refreshed, composed, decomposed].map { Data($0.utf8) })
        XCTAssertTrue(session.scriptIssues.isEmpty); XCTAssertNil(session.failure)
        try await session.close(); XCTAssertTrue(session.rawJSONReports.isEmpty)
    }

    func testRawJSONReportsResetAtRestartAndRetiredCallbacksCannotPublish() async throws {
        let first = PreviewPageFixture(), second = PreviewPageFixture(); var pages = [first, second]
        let session = EditorScenePreviewSession(makePage: { pages.removeFirst() }, cleanup: {})
        try session.start(); first.onSceneScriptRawIssue?(#"{"message":"\ud83d","count":1}"#)
        XCTAssertEqual(session.rawJSONReports.count, 1)
        let stale = first.onSceneScriptRawIssue
        try await session.restart(); XCTAssertTrue(session.rawJSONReports.isEmpty)
        stale?(#"{"message":"\ud83d","count":2}"#); XCTAssertTrue(session.rawJSONReports.isEmpty)
        second.onSceneScriptRawIssue?(#"{"message":"\ud83d","count":3}"#)
        XCTAssertEqual(session.rawJSONReports.count, 1)
        try await session.close(); second.onSceneScriptRawIssue?("late")
        XCTAssertTrue(session.rawJSONReports.isEmpty)
    }

    func testRawJSONListIsExplicitSelectableUnmappedAndKeepsSelectionIdentity() async throws {
        _ = NSApplication.shared
        let page = PreviewPageFixture()
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {})
        let controller = EditorScenePreviewWindowController(session: session, title: "Raw diagnostics")
        controller.capturedScripts = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": [["id": 1, "alpha": ["script": "captured"]]]])
        controller.onSource = { _ in XCTFail("Raw JSON cannot navigate to guessed source") }
        try controller.start()
        let raw = #"{"layerId":1,"layerName":"","target":"alpha","phase":"update","message":"\ud83d","line":2,"count":3}"#
        page.onSceneScriptRawIssue?(raw)
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        let controls = children(try XCTUnwrap(controller.window?.contentView))
        let table = try XCTUnwrap(controls.compactMap { $0 as? NSTableView }.first)
        let open = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == text("diagnosticOpenSource") })
        let status = try XCTUnwrap(controls.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(table.numberOfRows, 1); XCTAssertFalse(open.isEnabled)
        XCTAssertTrue(status.isSelectable); XCTAssertFalse(status.isEditable)
        XCTAssertTrue(status.string.contains(raw)); XCTAssertTrue(status.string.contains(text("diagnosticRawJSON")))
        XCTAssertTrue(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == text("diagnosticRawJSONReason") })
        page.onDiagnostic?(["message": "later console"])
        page.onSceneScriptIssue?(["layerId": 1, "layerName": "", "target": "alpha", "phase": "update", "message": "later script", "line": 1, "count": 1])
        XCTAssertEqual(table.selectedRow, 2); XCTAssertFalse(open.isEnabled)
        XCTAssertTrue(status.string.contains(raw))
        open.performClick(nil)
        try await controller.requestClose()
    }

    func testPreviewRuntimeIsPackagedWithTheExactMainRuntimeBytes() throws {
        let bundled = try EditorNativeScenePreviewPage.runtimeDirectory()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let original = repository.appendingPathComponent("Sources/WallpaperApp/Resources/SceneRuntime")
        let names = try FileManager.default.contentsOfDirectory(atPath: original.path).sorted()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: bundled.path).contains("scene-preview-api.mjs"))
        for name in names where name != "scene-shell.mjs" {
            XCTAssertEqual(try Data(contentsOf: bundled.appendingPathComponent(name)),
                           try Data(contentsOf: original.appendingPathComponent(name)), name)
        }
    }

    func testSnapshotParsingPreservesUnsavedSourceAndResourceVersions() throws {
        let baseline = try EditorProjectDocument(id: UUID(), revision: 4, title: "Saved", sceneEntry: "scene.json",
            sourcePackage: nil, scene: Data("{\"objects\":[]}".utf8), project: Data("{\"type\":\"scene\"}".utf8))
        let source = "// 编辑 😀\r\nexport function update(value){return value;}"
        let snapshot: [String: Any] = ["entry": "scene.json", "title": "Unsaved", "project": ["type": "scene", "future": true],
            "scene": ["objects": [["id": 1, "alpha": ["value": 1, "script": source, "future": ["kept": true]]]]],
            "resourceOverrides": ["body.mdl": String(repeating: "a", count: 64)]]
        let parsed = try EditorWindowController.snapshotDocument(snapshot, basedOn: baseline)
        XCTAssertEqual(parsed.id, baseline.id); XCTAssertEqual(parsed.revision, 4)
        XCTAssertEqual(parsed.title, "Unsaved"); XCTAssertEqual(parsed.schemaVersion, 2)
        let scene = try XCTUnwrap(JSONSerialization.jsonObject(with: parsed.scene) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: scene), NSDictionary(dictionary: snapshot["scene"] as! [String: Any]))
        var invalid = snapshot; invalid["entry"] = "different.json"
        XCTAssertThrowsError(try EditorWindowController.snapshotDocument(invalid, basedOn: baseline))
        invalid = snapshot; invalid["resourceOverrides"] = ["body.mdl": "wrong"]
        XCTAssertThrowsError(try EditorWindowController.snapshotDocument(invalid, basedOn: baseline))
    }

    func testNativeRetainedListSelectsCapturedSourceAndLeavesGenericEntriesUnmapped() async throws {
        _ = NSApplication.shared
        let page = PreviewPageFixture()
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {})
        let controller = EditorScenePreviewWindowController(session: session, title: "Issues")
        controller.capturedScripts = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": [["id": 1, "alpha": ["script": "// 世界😀\r\nthrow Error()"]]]])
        var opened: [EditorCapturedScriptLink] = []; controller.onSource = { opened.append($0) }
        try controller.start()
        page.onSceneScriptIssue?(["layerId": 1, "layerName": "", "target": "alpha", "phase": "update", "message": "first issue", "line": 2, "count": 3])
        page.onDiagnostic?(["message": "generic issue"])
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        let controls = children(try XCTUnwrap(controller.window?.contentView))
        let table = try XCTUnwrap(controls.compactMap { $0 as? NSTableView }.first)
        let open = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == text("diagnosticOpenSource") })
        XCTAssertEqual(table.numberOfRows, 2); XCTAssertTrue(open.isEnabled)
        XCTAssertEqual(open.keyEquivalent, "o"); XCTAssertEqual(open.keyEquivalentModifierMask, [.command, .shift])
        open.performClick(nil)
        XCTAssertEqual(opened.count, 1); XCTAssertEqual(opened.first?.line, 2)
        XCTAssertEqual(opened.first?.source, "// 世界😀\r\nthrow Error()")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertFalse(open.isEnabled)
        let status = try XCTUnwrap(controls.compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(status.string.contains("generic issue"))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(status.string.contains("first issue")); XCTAssertTrue(status.string.contains("×3"))
        try await controller.requestClose()
        XCTAssertNil(controller.onSource); XCTAssertNil(controller.capturedScripts)
    }

    func testConsoleSelectionRemainsUnmappedWhenScriptIssueIsInsertedAheadOfIt() async throws {
        _ = NSApplication.shared
        let page = PreviewPageFixture()
        let session = EditorScenePreviewSession(makePage: { page }, cleanup: {})
        let controller = EditorScenePreviewWindowController(session: session, title: "Stable selection")
        controller.capturedScripts = try EditorCapturedScriptSnapshot(documentIdentity: "capture", scene: ["objects": [["id": 1, "alpha": ["script": "captured"]]]])
        controller.onSource = { _ in XCTFail("Console selection cannot open source") }
        try controller.start()
        page.onDiagnostic?(["message": "selected console warning"])
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        let controls = children(try XCTUnwrap(controller.window?.contentView))
        let table = try XCTUnwrap(controls.compactMap { $0 as? NSTableView }.first)
        let open = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == text("diagnosticOpenSource") })
        let status = try XCTUnwrap(controls.compactMap { $0 as? NSTextView }.first)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertFalse(open.isEnabled)
        page.onSceneScriptIssue?(["layerId": 1, "layerName": "", "target": "alpha", "phase": "update", "message": "script failure", "line": NSNull(), "count": 1])
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertEqual(table.selectedRow, 1, "A new script issue must not replace the selected console entry")
        XCTAssertFalse(open.isEnabled, "Retained console entries remain unmapped")
        XCTAssertTrue(status.string.contains("selected console warning"))
        try await controller.requestClose()
    }

    func testNativeWindowMinimumLayoutInFiveLanguagesAndBothAppearances() async throws {
        DWWebCreateApplication()
        let resourceRoot = try EditorNativeScenePreviewPage.runtimeDirectory().deletingLastPathComponent()
        let runtime = DWWebRuntime(frameworkDirectory: "/unstarted-test-framework", helperExecutable: "/unstarted-test-helper", cacheDirectory: "/unstarted-test-cache")
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        for language in ["en", "zh-Hans", "ja", "fr", "es"] {
            let bundle = try XCTUnwrap(Bundle(path: resourceRoot.appendingPathComponent(language + ".lproj").path))
            let localize: (String) -> String = { bundle.localizedString(forKey: $0, value: nil, table: nil) }
            XCTAssertNotEqual(localize("previewPause"), "previewPause")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let controller = EditorScenePreviewWindowController(project: SceneProjectReference(root: root, entry: "scene.json", representation: .loose),
                title: "Layout", runtime: runtime, localize: localize)
            let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
            window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance); content.layoutSubtreeIfNeeded()
                let controls = children(content)
                let buttons = controls.compactMap { $0 as? NSButton }.filter { $0.target === controller }
                XCTAssertEqual(buttons.count, 5)
                XCTAssertEqual(Set(buttons.map(\.title)), Set([localize("previewPause"), localize("previewRestart"), localize("diagnosticOpenSource"), localize("previewAudioEnabled"), localize("previewAudioRetry")]))
                let labels = controls.compactMap { $0 as? NSTextField }
                XCTAssertTrue(labels.contains { $0.stringValue == localize("previewSnapshotNote") })
                let visible: [NSView] = (buttons + labels + controls.compactMap({ $0 as? NSScrollView })).filter { !$0.isHidden }
                for view in visible {
                    view.scrollToVisible(view.bounds); content.layoutSubtreeIfNeeded()
                    let frame = view.convert(view.bounds, to: content)
                    XCTAssertGreaterThanOrEqual(frame.minX, -1, language)
                    XCTAssertGreaterThanOrEqual(frame.minY, -1, language)
                    XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width + 1, language)
                    XCTAssertLessThanOrEqual(frame.maxY, content.bounds.height + 1, language)
                }
                let diagnostics = try XCTUnwrap(controls.compactMap { $0 as? NSTextView }.first)
                XCTAssertFalse(diagnostics.isEditable); XCTAssertFalse(diagnostics.isRichText)
                XCTAssertTrue(diagnostics.isSelectable)
            }
            // No native page or CEF runtime was started by this layout test.
            try await controller.requestClose()
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
        XCTAssertEqual(runtime.initializationCount, 0)
    }
}
