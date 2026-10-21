import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class InspectorMediaModelTests: XCTestCase {
    func testReplacementWaitsAndNeverPublishesOldRecommendation() async throws {
        let probe = SuspendedInspection()
        let model = InspectorMediaModel(inspect: probe.run)
        model.select(item("first"))
        try await wait { probe.starts.count == 1 }
        let second = item("second")
        model.select(second)
        XCTAssertNil(model.transcodeReason)
        XCTAssertNil(model.image)
        XCTAssertEqual(probe.starts.count, 1)
        probe.finish(.success(MediaInspection(image: nil, transcodeReason: "old incompatibility")))
        try await wait { probe.starts.count == 2 }
        XCTAssertNil(model.transcodeReason)
        probe.finish(.success(MediaInspection(image: NSImage(size: NSSize(width: 1, height: 1)), transcodeReason: nil)))
        try await wait { !model.isChecking }
        XCTAssertEqual(model.source?.id, second.id)
        XCTAssertNotNil(model.image)
        XCTAssertNil(model.transcodeReason)
        try await model.beginShutdown().value
    }

    func testOrdinaryFailureIsVisibleAndExplicitRetryCanSucceed() async throws {
        let probe = SuspendedInspection()
        let model = InspectorMediaModel(inspect: probe.run)
        model.select(item("source"))
        try await wait { probe.starts.count == 1 }
        probe.finish(.failure(WallpaperError("file is offline")))
        try await wait { !model.isChecking }
        XCTAssertEqual(model.errorMessage, "file is offline")
        XCTAssertNil(model.transcodeReason)
        model.retry()
        try await wait { probe.starts.count == 2 }
        XCTAssertNil(model.errorMessage)
        probe.finish(.success(MediaInspection(image: NSImage(size: NSSize(width: 1, height: 1)), transcodeReason: nil)))
        try await wait { !model.isChecking }
        XCTAssertNotNil(model.image)
        try await model.beginShutdown().value
    }

    func testClearingSelectionAndShutdownStillDrainInFlightWork() async throws {
        let probe = SuspendedInspection()
        let model = InspectorMediaModel(inspect: probe.run)
        model.select(item("source"))
        try await wait { probe.starts.count == 1 }
        model.select(nil)
        XCTAssertNil(model.source)
        var completed = false
        let closing = Task { try await model.beginShutdown().value; completed = true }
        await Task.yield()
        XCTAssertFalse(completed)
        probe.finish(.failure(CancellationError()))
        try await closing.value
        XCTAssertTrue(completed)
        XCTAssertEqual(probe.starts.count, 1)
    }

    func testCleanupFailureSurvivesReplacementAndBlocksApplicationShutdown() async throws {
        let directory = try TranscodeTestFixtures.directory()
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        let probe = SuspendedInspection()
        let inspector = InspectorMediaModel(inspect: probe.run)
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let app = AppModel(store: store, inspectorMedia: inspector)
        inspector.select(item("first"))
        try await wait { probe.starts.count == 1 }
        inspector.select(item("second"))
        let closing = Task { try await app.shutdownAndWait() }
        probe.finish(.failure(TranscodeCleanupFailure(operation: "Close diagnostic", cleanup: WallpaperError("still open"))))
        do { try await closing.value; XCTFail("A failed diagnostic release cannot claim a clean app exit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("still open")) }
        XCTAssertEqual(probe.starts.count, 1)
        XCTAssertTrue(app.errorMessage?.contains("still open") == true)
    }

    func testThumbnailCleanupFailureRetainsSurfaceAndIsNotOrdinaryMediaFailure() async throws {
        var surface: ControlledSurface? = ControlledSurface()
        weak let retained = surface
        surface?.closeError = WallpaperError("surface did not close")
        let inspector = InspectorMediaModel(inspect: { _ in
            let current = try XCTUnwrap(surface)
            return try await MediaProbeCleanup.withSurface(current) {
                throw WallpaperError("decoding failed")
            }
        })
        inspector.select(item("source"))
        try await wait { !inspector.isChecking }
        surface = nil
        XCTAssertNotNil(retained, "The failed cleanup must retain the uncertain backend")
        XCTAssertTrue(inspector.errorMessage?.contains("decoding failed") == true)
        XCTAssertTrue(inspector.errorMessage?.contains("surface did not close") == true)
        do { try await inspector.beginShutdown().value; XCTFail("Failed surface close must remain a release error") }
        catch { XCTAssertTrue(error is MediaProbeCleanupFailure) }
    }

    func testThumbnailCleanupWaitsEvenWhenOperationIsCancelled() async throws {
        let surface = ControlledSurface()
        surface.holdClose = true
        var finished = false
        let task = Task<Void, Error> {
            defer { finished = true }
            try await MediaProbeCleanup.withSurface(surface) { throw CancellationError() }
        }
        await fulfillment(of: [surface.closeStarted], timeout: 1)
        XCTAssertFalse(finished)
        surface.finishClose()
        do { try await task.value; XCTFail("Cancellation must propagate after cleanup") }
        catch is CancellationError { }
        XCTAssertEqual(surface.state, .closed)
    }

    func testCancellationDuringSuccessfulThumbnailCleanupDoesNotReturnSuccess() async throws {
        let surface = ControlledSurface()
        surface.holdClose = true
        let task = Task {
            try await MediaProbeCleanup.withSurface(surface) { 42 }
        }
        await fulfillment(of: [surface.closeStarted], timeout: 1)
        task.cancel()
        surface.finishClose()
        do { _ = try await task.value; XCTFail("Cancellation while releasing must not return a successful thumbnail") }
        catch is CancellationError { }
        XCTAssertEqual(surface.state, .closed)
    }

    private func item(_ name: String) -> MediaItem {
        MediaItem(url: URL(fileURLWithPath: "/tmp/\(name).mov"), kind: .video, width: 64, height: 64)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Inspector test timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class SuspendedInspection {
    var starts: [UUID] = []
    private var completion: CheckedContinuation<MediaInspection, Error>?
    func run(_ item: MediaItem) async throws -> MediaInspection {
        starts.append(item.id)
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func finish(_ result: Result<MediaInspection, Error>) {
        let current = completion
        completion = nil
        current?.resume(with: result)
    }
}
