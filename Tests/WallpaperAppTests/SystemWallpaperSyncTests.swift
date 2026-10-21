import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SystemWallpaperSyncTests: XCTestCase {
    func testDisabledDoesNotWriteAndExitKeepsLastSuccessfulFile() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        var writes: [URL] = [], captures = 0
        let sync = SystemWallpaperSync(store: files.store, capture: { _ in
            captures += 1; return try SystemWallpaperFiles.image()
        }, isCurrent: { _ in true }, apply: { url, _ in writes.append(url) })
        sync.updateTargets([try files.target()])
        await sync.waitForPendingOperations()
        XCTAssertEqual(captures, 0)
        sync.setEnabled(true)
        await sync.waitForPendingOperations()
        XCTAssertEqual(captures, 1)
        let url = try XCTUnwrap(writes.first)
        XCTAssertEqual(sync.states["A"], .synced(url))
        sync.setEnabled(false)
        sync.updateTargets([])
        sync.shutdown()
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testRepeatedTargetDoesNotWriteAndNewCommitReusesFixedPoster() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        var writes: [URL] = [], captures = 0
        let sync = SystemWallpaperSync(store: files.store, capture: { _ in
            captures += 1; return try SystemWallpaperFiles.image()
        }, isCurrent: { _ in true }, apply: { url, _ in writes.append(url) })
        let first = try files.target()
        sync.setEnabled(true)
        sync.updateTargets([first])
        await sync.waitForPendingOperations()
        sync.updateTargets([first])
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.count, 1)
        sync.updateTargets([try files.target()])
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.first, writes.last)
        XCTAssertEqual(captures, 1)
        sync.shutdown()
    }

    func testSupersededCaptureCannotOverwriteNewerCommit() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let old = try files.target(), newest = try files.target()
        let oldStarted = expectation(description: "old capture started")
        let newStarted = expectation(description: "new capture started")
        var pending: [UUID: CheckedContinuation<CGImage, Error>] = [:]
        var writes: [URL] = []
        let sync = SystemWallpaperSync(store: files.store, capture: { target in
            try await withCheckedThrowingContinuation { continuation in
                pending[target.revision] = continuation
                (target == old ? oldStarted : newStarted).fulfill()
            }
        }, isCurrent: { _ in true }, apply: { url, _ in writes.append(url) })
        sync.setEnabled(true)
        sync.updateTargets([old])
        await fulfillment(of: [oldStarted], timeout: 2)
        sync.updateTargets([newest])
        await fulfillment(of: [newStarted], timeout: 2)
        try XCTUnwrap(pending.removeValue(forKey: newest.revision)).resume(returning: SystemWallpaperFiles.image(red: 0))
        try XCTUnwrap(pending.removeValue(forKey: old.revision)).resume(returning: SystemWallpaperFiles.image())
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.count, 1)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: XCTUnwrap(writes.first))))
        XCTAssertGreaterThan(try bitmap.sRGBColor(atX: 4, y: 3).blueComponent, 0.9)
        sync.shutdown()
    }

    func testDisableUnbindAndShutdownWaitForCaptureWithoutLateWrites() async throws {
        for action in ["disable", "unbind", "shutdown"] {
            let files = try SystemWallpaperFiles()
            defer { try? files.remove() }
            let started = expectation(description: action)
            var pending: CheckedContinuation<CGImage, Error>?
            var writes = 0, drained = false
            let sync = SystemWallpaperSync(store: files.store, capture: { _ in
                try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
            }, isCurrent: { _ in true }, apply: { _, _ in writes += 1 })
            sync.setEnabled(true)
            sync.updateTargets([try files.target()])
            await fulfillment(of: [started], timeout: 2)
            switch action {
            case "disable": sync.setEnabled(false)
            case "unbind": sync.updateTargets([])
            default: sync.shutdown()
            }
            let waiting = Task { await sync.waitForPendingOperations(); drained = true }
            await Task.yield()
            XCTAssertFalse(drained, "A cancelled capture still owns resources")
            try XCTUnwrap(pending).resume(returning: SystemWallpaperFiles.image())
            await waiting.value
            XCTAssertEqual(writes, 0)
            sync.shutdown()
        }
    }

    func testDisplaysFailIndependentlyAndOnlyExplicitRetryRetries() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        var writes: [String] = [], failB = true
        let sync = SystemWallpaperSync(store: files.store, capture: { _ in try SystemWallpaperFiles.image() },
            isCurrent: { _ in true }, apply: { _, display in
                writes.append(display)
                if display == "B", failB { throw WallpaperError("test system refusal", diagnostic: "B-error") }
            })
        let targets = try [files.target("A"), files.target("B")]
        sync.setEnabled(true)
        sync.updateTargets(targets)
        await sync.waitForPendingOperations()
        guard case .synced = sync.states["A"] else { return XCTFail("A must succeed") }
        guard case let .failed(failure) = sync.states["B"] else { return XCTFail("B must report failure") }
        XCTAssertEqual(failure.summary, "test system refusal")
        XCTAssertEqual(failure.diagnostics, "B-error")
        sync.updateTargets(targets)
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.count, 2)
        failB = false
        sync.retry(displayID: "B")
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes.filter { $0 == "A" }.count, 1)
        XCTAssertEqual(writes.filter { $0 == "B" }.count, 2)
        guard case .synced = sync.states["B"] else { return XCTFail("Explicit retry must succeed") }
        sync.shutdown()
    }

    func testInvalidatedSourceAndCaptureFailureCannotSetSystemImage() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        var current = true, writes = 0
        let sync = SystemWallpaperSync(store: files.store, capture: { _ in
            current = false; return try SystemWallpaperFiles.image()
        }, isCurrent: { _ in current }, apply: { _, _ in writes += 1 })
        sync.setEnabled(true)
        sync.updateTargets([try files.target()])
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(sync.states["A"], .waiting)
        sync.shutdown()
        let broken = SystemWallpaperSync(store: files.store, capture: { _ in throw WallpaperError("capture failed") },
            isCurrent: { _ in true }, apply: { _, _ in writes += 1 })
        broken.setEnabled(true)
        broken.updateTargets([try files.target()])
        await broken.waitForPendingOperations()
        guard case let .failed(failure) = broken.states["A"] else { return XCTFail("Capture failure hidden") }
        XCTAssertEqual(failure.summary, "capture failed")
        XCTAssertEqual(writes, 0)
        broken.shutdown()
    }
}
