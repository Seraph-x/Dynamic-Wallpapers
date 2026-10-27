import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ScenePropertyControlTests: XCTestCase {
    func testRemovalDrainsAnEarlierReaderWithoutClearingCurrentSelection() async throws {
        let first = scene(), second = scene(), capture = try capture()
        let entered = expectation(description: "Removed media reader entered")
        let selected = expectation(description: "Current media reader finished")
        var held: CheckedContinuation<ScenePropertyCatalogCapture, Never>?
        let editor = ScenePropertyEditorModel(read: { item in
            if item.id == first.id {
                entered.fulfill()
                return await withCheckedContinuation { held = $0 }
            }
            selected.fulfill(); return capture
        }, revalidate: { _ in }, currentItem: { _ in second },
            commit: { item, _ in return item }, publish: { _, _, _ in })
        editor.select(first); await fulfillment(of: [entered], timeout: 2)
        editor.select(second); await fulfillment(of: [selected], timeout: 2)
        let removal = editor.beginRemovingMedia([first.id])
        var removed = false
        let draining = Task { try await removal.value; removed = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(removed)
        XCTAssertNotNil(editor.catalog)
        held?.resume(returning: capture)
        try await draining.value
        XCTAssertTrue(removed)
        XCTAssertNotNil(editor.catalog)
        editor.shutdown(); await editor.waitForLoading()
    }

    func testShutdownDrainsSaveRevalidationBeforeReportingCompletion() async throws {
        let item = scene(), capture = try capture()
        let entered = expectation(description: "Save is actually revalidating metadata")
        var held: CheckedContinuation<Void, Never>?, commits = 0
        let editor = ScenePropertyEditorModel(read: { _ in capture }, revalidate: { _ in
            entered.fulfill(); await withCheckedContinuation { held = $0 }
        }, currentItem: { _ in item }, commit: { item, _ in commits += 1; return item }, publish: { _, _, _ in })
        editor.select(item); await editor.waitForLoading()
        let saving = Task { await editor.save() }
        await fulfillment(of: [entered], timeout: 2)
        var finished = false
        let stopping = Task { editor.shutdown(); await editor.waitForLoading(); finished = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished, "Save revalidation must retain its metadata reader until completion")
        held?.resume(); await stopping.value
        let saved = await saving.value
        XCTAssertFalse(saved); XCTAssertEqual(commits, 0)
    }

    func testShutdownWaitsForCancelledMetadataFromAnEarlierSelection() async throws {
        let first = scene(), capture = try capture()
        var second = scene(); second.scenePropertyOverrides = []
        let entered = expectation(description: "First selection is reading metadata")
        let replaced = expectation(description: "Replacement selection is reading metadata")
        var held: CheckedContinuation<ScenePropertyCatalogCapture, Never>?
        let editor = ScenePropertyEditorModel(read: { item in
            if item.id == first.id {
                entered.fulfill()
                return await withCheckedContinuation { held = $0 }
            }
            replaced.fulfill(); return capture
        }, revalidate: { _ in }, currentItem: { _ in second },
            commit: { item, _ in XCTFail("Shutdown must not save"); return item }, publish: { _, _, _ in })
        editor.select(first); await fulfillment(of: [entered], timeout: 2)
        editor.select(second); await fulfillment(of: [replaced], timeout: 2)
        var finished = false
        let stopping = Task { editor.shutdown(); await editor.waitForLoading(); finished = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(finished, "A cancelled earlier reader must remain owned until it actually finishes")
        held?.resume(returning: capture)
        await stopping.value
        XCTAssertTrue(finished); XCTAssertNil(editor.catalog)
    }

    private let reference = SceneProjectReference(root: URL(fileURLWithPath: "/project"), entry: "scene.json", representation: .loose)
    private let bytes = Data(#"{"general":{"properties":{"caption":{"type":"textinput","value":"Default"},"enabled":{"type":"bool","value":true}}}}"#.utf8)

    func testSaveCommitsBeforeLiveAndDiskFailureNeverPublishes() async throws {
        let item = scene()
        let capture = try capture()
        var current = item, events: [String] = [], diskFailure = true
        let editor = ScenePropertyEditorModel(read: { _ in capture }, revalidate: { _ in },
            currentItem: { _ in current }, commit: { _, values in
                events.append("save")
                if diskFailure { throw WallpaperError("disk denied") }
                current.scenePropertyOverrides = values; return current
            }, publish: { _, _, _ in events.append("live") })
        editor.select(item); await editor.waitForLoading()
        let row = try XCTUnwrap(editor.catalog?.rows.first { $0.name == "caption" })
        editor.setValue(.string("Saved"), for: row)
        await assertResult(false, await editor.save())
        XCTAssertEqual(events, ["save"])
        XCTAssertTrue(current.scenePropertyOverrides.isEmpty)
        XCTAssertNotNil(editor.failure)
        diskFailure = false
        await assertResult(true, await editor.save())
        XCTAssertEqual(events, ["save", "save", "live"])
        XCTAssertEqual(current.scenePropertyOverrides, [.init(name: "caption", value: .string("Saved"))])
    }

    func testStaleMetadataSelectionDeletionAndShutdownCannotSave() async throws {
        let item = scene(), capture = try capture()
        var current: MediaItem? = item, stale = false, commits = 0
        let editor = ScenePropertyEditorModel(read: { _ in capture }, revalidate: { _ in
            if stale { throw WallpaperError("metadata changed") }
        }, currentItem: { _ in current }, commit: { item, _ in commits += 1; return item }, publish: { _, _, _ in })
        editor.select(item); await editor.waitForLoading()
        stale = true; await assertResult(false, await editor.save()); XCTAssertEqual(commits, 0)
        stale = false; current = nil; await assertResult(false, await editor.save()); XCTAssertEqual(commits, 0)
        current = item; editor.select(nil); await assertResult(false, await editor.save()); XCTAssertEqual(commits, 0)
        editor.select(item); await editor.waitForLoading()
        editor.shutdown(); await assertResult(false, await editor.save()); XCTAssertEqual(commits, 0)
    }

    func testInvalidStoredValuesRemainVisibleAndExplicitResetDeliversDefaults() async throws {
        var item = scene(); item.scenePropertyOverrides = [.init(name: "removed", value: .boolean(true))]
        let capture = try capture()
        var current = item, delivered: [ScenePropertyOverride] = []
        let editor = ScenePropertyEditorModel(read: { _ in capture }, revalidate: { _ in }, currentItem: { _ in current },
            commit: { _, values in current.scenePropertyOverrides = values; return current },
            publish: { _, _, values in delivered = values })
        editor.select(item); await editor.waitForLoading()
        XCTAssertTrue(editor.hasInvalidStoredValues)
        XCTAssertNotNil(editor.failure)
        await assertResult(false, await editor.save())
        await assertResult(true, await editor.reset())
        XCTAssertTrue(current.scenePropertyOverrides.isEmpty)
        XCTAssertEqual(Set(delivered.map(\.identity)), Set(capture.catalog.rows.map(\.identity)))
        XCTAssertEqual(delivered.first { $0.name == "caption" }?.value, .string("Default"))
    }

    func testLiveFailureKeepsSavedValuesAndReportsSavedState() async throws {
        let item = scene(), capture = try capture()
        var current = item
        let editor = ScenePropertyEditorModel(read: { _ in capture }, revalidate: { _ in }, currentItem: { _ in current },
            commit: { _, values in current.scenePropertyOverrides = values; return current },
            publish: { _, _, _ in throw WallpaperError("browser rejected") })
        editor.select(item); await editor.waitForLoading()
        editor.setValue(.boolean(false), for: try XCTUnwrap(editor.catalog?.rows.first { $0.name == "enabled" }))
        await assertResult(false, await editor.save())
        XCTAssertEqual(current.scenePropertyOverrides, [.init(name: "enabled", value: .boolean(false))])
        XCTAssertEqual(editor.status, "设置已保存，实时应用失败")
        XCTAssertNotNil(editor.failure)
    }

    func testQueuedSaveAndResetCannotWriteAfterSelectionWasReplaced() async throws {
        let item = scene(), capture = try capture()
        var commits = 0
        let editor = ScenePropertyEditorModel(read: { _ in capture }, revalidate: { _ in }, currentItem: { _ in item },
            commit: { item, _ in commits += 1; return item }, publish: { _, _, _ in })
        editor.select(item); await editor.waitForLoading()
        let previous = editor.selectionRevision
        editor.select(item); await editor.waitForLoading()
        await assertResult(false, await editor.save(expectedRevision: previous))
        await assertResult(false, await editor.reset(expectedRevision: previous))
        XCTAssertEqual(commits, 0)
    }

    private func assertResult(_ expected: Bool, _ operation: @autoclosure () async -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await operation()
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func scene() -> MediaItem {
        MediaItem(url: reference.entryURL, kind: .scene, width: 64, height: 48, backend: .scene, sceneProject: reference)
    }
    private func capture() throws -> ScenePropertyCatalogCapture {
        ScenePropertyCatalogCapture(project: reference, catalog: try ScenePropertyCatalog(projectJSON: bytes), device: 1, inode: 2)
    }
}

@MainActor
final class ScenePropertySessionOwnerTests: XCTestCase {
    func testNativeSessionCloseDrainsAnActualDispatchedMetadataRead() async throws {
        let runtime = CEFApplicationRuntime(paths: .resolve(bundleURL: URL(fileURLWithPath: "/missing.app")))
        let media = item(), capture = try capture(media)
        let entered = expectation(description: "Actual metadata worker entered")
        let released = DispatchSemaphore(value: 0)
        let page = CEFScenePageSession(owner: runtime, size: CGSize(width: 64, height: 48), frameRate: .fps30,
            readProperties: { _ in entered.fulfill(); released.wait(); return capture })
        let preparing = Task { try await page.prepare(item: media, scale: 1, fit: .fit) }
        await fulfillment(of: [entered], timeout: 2)
        var closed = false
        let closing = Task { try await page.close(); closed = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closed, "Close must wait for its actual dispatched metadata reader")
        released.signal()
        do { try await preparing.value; XCTFail("Closed scene must not initialize a browser") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await closing.value
        XCTAssertTrue(closed)
        XCTAssertEqual(runtime.sceneProperties.count, 0)
        XCTAssertEqual(runtime.activePageCount, 0)
        try await runtime.shutdown()
    }

    func testFailedLatestUpdateCannotExposeAStalePreparedFrame() async throws {
        let owner = ScenePropertySessionOwner(), media = item(), id = UUID()
        let capture = try capture(media)
        var calls = 0
        owner.register(id, item: media)
        try await owner.prepare(id, capture: capture) { _ in
            calls += 1
            if calls > 1 { throw WallpaperError("Actual receiver rejected the latest values") }
        }
        do {
            try await owner.publish(item: media, capture: capture,
                values: [.init(name: "caption", value: .string("Latest"))])
            XCTFail("Expected actual receiver failure")
        } catch { XCTAssertTrue(error is WallpaperErrorGroup) }
        var attached = false
        do { try await owner.attach(id) { attached = true }; XCTFail("Failed latest values must prevent attachment") }
        catch { XCTAssertEqual((error as? WallpaperError)?.message, "Actual receiver rejected the latest values") }
        XCTAssertFalse(attached)
        owner.beginClose(id); try await owner.retire(id)
    }

    private func item(_ id: UUID = UUID()) -> MediaItem {
        let project = SceneProjectReference(root: URL(fileURLWithPath: "/project"), entry: "scene.json", representation: .loose)
        return MediaItem(id: id, url: project.entryURL, kind: .scene, width: 64, height: 48, backend: .scene, sceneProject: project)
    }
    private func capture(_ item: MediaItem) throws -> ScenePropertyCatalogCapture {
        ScenePropertyCatalogCapture(project: item.sceneProject!, catalog: try ScenePropertyCatalog(projectJSON:
            Data(#"{"general":{"properties":{"caption":{"type":"textinput","value":"Default"}}}}"#.utf8)), device: 1, inode: 2)
    }
    func testAllOwnedInstancesReceiveSerializedUpdatesAndPendingPreparationGetsLatestBeforeAttachment() async throws {
        let owner = ScenePropertySessionOwner(), media = item(), first = UUID(), second = UUID()
        let capture = try capture(media)
        owner.register(first, item: media); owner.register(second, item: media)
        var firstValues: [String] = [], secondValues: [String] = []
        try await owner.prepare(first, capture: capture) { data in firstValues.append(String(decoding: data, as: UTF8.self)) }
        let patch = [ScenePropertyOverride(name: "caption", value: .string("Live"))]
        try await owner.publish(item: media, capture: capture, values: patch)
        try await owner.prepare(second, capture: capture) { data in secondValues.append(String(decoding: data, as: UTF8.self)) }
        var attached = false
        try await owner.attach(second) { attached = true; XCTAssertEqual(secondValues.last, #"{"caption":"Live"}"#) }
        XCTAssertTrue(attached)
        XCTAssertEqual(firstValues, [#"{"caption":"Default"}"#, #"{"caption":"Live"}"#])
        XCTAssertEqual(secondValues, [#"{"caption":"Live"}"#])
        owner.beginClose(first); try await owner.retire(first)
        try await owner.publish(item: media, capture: capture, values: [.init(name: "caption", value: .string("Later"))])
        XCTAssertEqual(firstValues.count, 2)
        XCTAssertEqual(secondValues.last, #"{"caption":"Later"}"#)
        owner.beginClose(second); try await owner.retire(second)
        XCTAssertEqual(owner.count, 0)
    }

    func testCloseRetainsInflightCommandUntilActualDrainAndRejectsAttach() async throws {
        let owner = ScenePropertySessionOwner(), media = item(), id = UUID()
        let capture = try capture(media)
        owner.register(id, item: media)
        var held: CheckedContinuation<Void, Error>?
        let started = expectation(description: "Actual property receiver entered")
        let preparing = Task {
            try await owner.prepare(id, capture: capture) { _ in
                try await withCheckedThrowingContinuation { continuation in
                    held = continuation; started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        owner.beginClose(id)
        var retired = false
        let closing = Task { try await owner.retire(id); retired = true }
        await Task.yield()
        XCTAssertFalse(retired)
        do { try await owner.attach(id) { XCTFail("Closing page must never attach") }; XCTFail("Expected cancelled attach") }
        catch { XCTAssertTrue(error is CancellationError) }
        held?.resume()
        do { try await preparing.value } catch { XCTAssertTrue(error is CancellationError) }
        try await closing.value
        XCTAssertTrue(retired)
        XCTAssertEqual(owner.count, 0)
    }
}
