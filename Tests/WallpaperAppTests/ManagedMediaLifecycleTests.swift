import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ManagedMediaLifecycleTests: XCTestCase {
    func testRollbackDiskFailureStaysVisibleWithoutClaimingALiveReader() async throws {
        var stagedDirectory: URL?
        let fixture = try ManagedLifecycleFixture(importProbe: { copy in
            let directory = copy.stagedURL.deletingLastPathComponent()
            stagedDirectory = directory
            try FileManager.default.moveItem(at: directory, to: directory.appendingPathExtension("retained"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            throw WallpaperError("probe rejected file")
        })
        defer {
            do { try FileManager.default.removeItem(at: fixture.directory) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        let original = try fixture.image("source.png")
        fixture.model.importURLs([original])
        try await until { !fixture.model.importing }
        let failure = try XCTUnwrap(fixture.model.failure)
        XCTAssertTrue(failure.localizedDescription.contains("probe rejected file"))
        XCTAssertTrue(failure.localizedDescription.contains(try XCTUnwrap(stagedDirectory).path),
                      "Cleanup failure must identify the unresolved copy")
        XCTAssertTrue(fixture.model.library.media.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        do { try await fixture.model.shutdownAndWait() }
        catch { XCTFail("A disk rollback error is not an unreleased reader: \(error)") }
        XCTAssertEqual(fixture.model.failure, failure, "Shutdown must not hide the rollback failure")
    }

    func testImportProbeCloseFailureRetainsStagingAndBlocksShutdown() async throws {
        let surface = ControlledSurface()
        surface.closeError = WallpaperError("reader remains open")
        var stagedURL: URL?
        let fixture = try ManagedLifecycleFixture(importProbe: { copy in
            stagedURL = copy.stagedURL
            return try await MediaProbeCleanup.withSurface(surface) {
                throw WallpaperError("probe rejected file")
            }
        })
        fixture.model.importURLs([try fixture.image("source.png")])
        try await until { !fixture.model.importing }
        XCTAssertTrue(fixture.model.library.media.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(stagedURL).path))
        do { try await fixture.model.shutdownAndWait(); XCTFail("The failed reader close must block shutdown") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reader remains open")) }
        surface.closeError = nil
        try await surface.close()
        try FileManager.default.removeItem(at: fixture.directory)
    }

    func testCancellationKeepsEarlierFileFailureVisible() async throws {
        let gate = ManagedReadGate()
        let fixture = try ManagedLifecycleFixture(importProbe: { copy in
            await gate.wait()
            try Task.checkCancellation()
            return try await MediaProbe.inspect(copy.stagedURL)
        })
        defer { gate.release() }
        fixture.model.importURLs([fixture.directory.appendingPathComponent("missing.png"), try fixture.image("valid.png")])
        try await until { gate.started }
        fixture.model.cancelImport()
        gate.release()
        try await until { !fixture.model.importing }
        XCTAssertTrue(fixture.model.failure?.localizedDescription.contains("missing.png") == true)
        XCTAssertTrue(fixture.model.library.media.isEmpty)
        try await fixture.close()
    }

    func testUnrelatedInspectionReleaseFailureDoesNotBlockDeletion() async throws {
        let inspection = InspectorMediaModel { item in
            throw TranscodeCleanupFailure(operation: "retain first reader", cleanup: WallpaperError("reader release failed"),
                                          retainedFileURLs: [item.url])
        }
        let fixture = try ManagedLifecycleFixture(inspection: inspection)
        let first = try await fixture.importImage()
        let other = try await fixture.importURL(fixture.image("other.png"))
        inspection.select(first)
        try await until { !inspection.isChecking }
        fixture.model.removeMedia(other.id)
        await fixture.model.waitForMediaRemovals()
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        do { try await fixture.model.shutdownAndWait(); XCTFail("The first reader's release failure must still block shutdown") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reader release failed")) }
        try FileManager.default.removeItem(at: fixture.directory)
    }

    func testInheritedInspectionFailureDoesNotClaimUnreadSelection() async throws {
        var inspected: [UUID] = []
        let inspection = InspectorMediaModel { item in
            inspected.append(item.id)
            throw TranscodeCleanupFailure(operation: "close first reader", cleanup: WallpaperError("release failed"),
                                          retainedFileURLs: [item.url])
        }
        let first = MediaItem(url: URL(fileURLWithPath: "/first.png"), kind: .image, width: 2, height: 2)
        let second = MediaItem(url: URL(fileURLWithPath: "/second.png"), kind: .image, width: 2, height: 2)
        inspection.select(first)
        try await until { !inspection.isChecking }
        inspection.select(second)
        try await until { !inspection.isChecking }
        XCTAssertEqual(inspected, [first.id])
        do { try await inspection.beginRemovingMedia([second.id]).value }
        catch { XCTFail("An unread selection must not inherit file ownership: \(error)") }
        do { try await inspection.beginRemovingMedia([first.id]).value; XCTFail("First reader is still unreleased") }
        catch { XCTAssertTrue(error.localizedDescription.contains("release failed")) }
        do { try await inspection.beginShutdown().value; XCTFail("First reader must still block shutdown") }
        catch { XCTAssertTrue(error.localizedDescription.contains("release failed")) }
    }

    func testRemovingQueuedInspectionDoesNotWaitForUnrelatedReader() async throws {
        let gate = ManagedReadGate()
        let inspection = InspectorMediaModel { _ in await gate.wait(); throw CancellationError() }
        defer { gate.release() }
        let first = MediaItem(url: URL(fileURLWithPath: "/first.png"), kind: .image, width: 2, height: 2)
        let second = MediaItem(url: URL(fileURLWithPath: "/second.png"), kind: .image, width: 2, height: 2)
        inspection.select(first)
        try await until { gate.started }
        inspection.select(second)
        let removal = inspection.beginRemovingMedia([second.id])
        let removed = expectation(description: "Unread selection can be removed while the first reader drains")
        let observing = Task { try await removal.value; removed.fulfill() }
        await fulfillment(of: [removed], timeout: 1)
        XCTAssertEqual(gate.calls, 1)
        gate.release()
        try await observing.value
        try await inspection.beginShutdown().value
    }

    func testShutdownCancelsWholeImportAndWaitsForProbeRelease() async throws {
        let gate = ManagedReadGate()
        let fixture = try ManagedLifecycleFixture(importProbe: { copy in
            if copy.url.lastPathComponent == "second.png" { await gate.wait() }
            try Task.checkCancellation()
            return try await MediaProbe.inspect(copy.stagedURL)
        })
        defer { gate.release() }
        let before = fixture.model.library
        let sources = try [fixture.image("first.png"), fixture.image("second.png")]
        fixture.model.importURLs(sources)
        try await until { gate.started }
        XCTAssertFalse(fixture.model.clearMediaLibrary(), "Clearing must not race an in-progress import")
        XCTAssertNil(fixture.model.lastLibraryBackup)
        var finished = false
        let shutdown = Task { try await fixture.model.shutdownAndWait(); finished = true }
        try await until { fixture.model.isShuttingDown }
        XCTAssertFalse(finished)
        XCTAssertTrue(fixture.model.importing)
        XCTAssertEqual(fixture.model.library, before)
        gate.release()
        try await shutdown.value
        XCTAssertFalse(fixture.model.importing)
        XCTAssertEqual(try fixture.model.store.load(), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("Media").path), [])
        for source in sources { XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)) }
        try await fixture.close()
    }

    func testRemovalDrainsThumbnailAndRejectsAStaleCardRequest() async throws {
        let gate = ManagedReadGate()
        let thumbnails = ThumbnailLifetime { item in
            await gate.wait()
            try Task.checkCancellation()
            return try await MediaThumbnail.load(item)
        }
        let fixture = try ManagedLifecycleFixture(thumbnails: thumbnails)
        defer { gate.release() }
        let item = try await fixture.importImage()
        let reading = Task { try await thumbnails.load(item) }
        try await until { gate.started }
        fixture.model.removeMedia(item.id)
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(fixture.model.library.pendingMediaDeletions, [item])
        gate.release()
        if case .success = await reading.result { XCTFail("Deleted thumbnail request must be cancelled") }
        await fixture.model.waitForMediaRemovals()
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        do { _ = try await thumbnails.load(item); XCTFail("A stale card must not reopen removed media") }
        catch is CancellationError { }
        XCTAssertEqual(gate.calls, 1)
        try await fixture.close()
    }

    func testRemovalDrainsInspectionAndClosesTheActivePreview() async throws {
        let gate = ManagedReadGate()
        let inspection = InspectorMediaModel { item in
            await gate.wait()
            try Task.checkCancellation()
            return try await MediaCompatibility.inspect(item)
        }
        let fixture = try ManagedLifecycleFixture(inspection: inspection)
        defer { gate.release() }
        let item = try await fixture.importImage()
        let request = PreviewLifetime.Request(id: UUID(), item: item, size: CGSize(width: 24, height: 24), scale: 1, fit: .fit)
        _ = try await fixture.model.previewLifetime.prepare(request, configure: { _ in }, onError: { XCTFail("\($0)") })
        inspection.select(item)
        try await until { gate.started }
        fixture.model.removeMedia(item.id)
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertNil(inspection.source)
        gate.release()
        await fixture.model.waitForMediaRemovals()
        XCTAssertEqual(fixture.model.previewLifetime.activeSurfaceCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        do {
            _ = try await fixture.model.previewLifetime.prepare(request, configure: { _ in }, onError: { XCTFail("\($0)") })
            XCTFail("A stale preview must not reopen removed media")
        } catch is CancellationError { }
        try await fixture.close()
    }

    func testTranscodeProbeBlocksOnlyTheFileItUses() async throws {
        let gate = ManagedReadGate()
        let transcode = TranscodeModel(inspect: { _ in await gate.wait(); throw CancellationError() })
        let fixture = try ManagedLifecycleFixture(transcoding: transcode)
        defer { gate.release() }
        let temporaryVideo = try await VideoIntegrationTests.makeVideo()
        let videoSource = fixture.directory.appendingPathComponent("source.mp4")
        try FileManager.default.moveItem(at: temporaryVideo, to: videoSource)
        let video = try await fixture.importURL(videoSource)
        let other = try await fixture.importImage()
        transcode.select(video)
        try await until { gate.started }
        fixture.model.removeMedia(video.id)
        XCTAssertTrue(fixture.model.library.media.contains(video))
        XCTAssertTrue(fixture.model.library.pendingMediaDeletions.isEmpty)
        XCTAssertNotNil(fixture.model.failure)
        fixture.model.removeMedia(other.id)
        await fixture.model.waitForMediaRemovals()
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.url.path))
        XCTAssertTrue(transcode.isProbing)
        gate.release()
        try await until { !transcode.isProbing }
        fixture.model.removeMedia(video.id)
        await fixture.model.waitForMediaRemovals()
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.url.path))
        XCTAssertNil(transcode.source)
        try await fixture.close()
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Managed media lifecycle test timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
