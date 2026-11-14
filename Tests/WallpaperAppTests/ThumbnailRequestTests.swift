import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ThumbnailRequestTests: XCTestCase {
    private struct ReleaseFailure: TranscodeReleaseError {
        let retainedFileURLs: Set<URL> = []
    }

    func testSharedReleaseFailureIsReportedOnceAndStillBlocksDraining() async throws {
        let gate = AsyncTestGate()
        let lifetime = ThumbnailLifetime { _ in
            try await gate.pause()
            throw ReleaseFailure()
        }
        var reports = 0
        lifetime.onReleaseError = { _ in reports += 1 }
        let item = makeItem()
        let first = Task { try await lifetime.load(item) }
        await gate.waitForArrival()
        let second = Task { try await lifetime.load(item) }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Release failure was hidden") }
            catch is ReleaseFailure { }
        }
        XCTAssertEqual(reports, 1)
        for task in [lifetime.beginRemovingMedia([item.id]), lifetime.beginShutdown()] {
            do { try await task.value; XCTFail("Unreleased decoder was forgotten") }
            catch is WallpaperErrorGroup { }
        }
    }

    func testOverlappingConsumersShareOneDecode() async throws {
        let gate = AsyncTestGate()
        var calls = 0
        let lifetime = ThumbnailLifetime { _ in
            calls += 1
            try await gate.pause()
            return NSImage(size: CGSize(width: 20, height: 20))
        }
        let item = makeItem()
        let first = Task { try await lifetime.load(item) }
        await gate.waitForArrival()
        let second = Task { try await lifetime.load(item) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1)
        await gate.release(); await gate.release()
        let firstImage = try await first.value
        let secondImage = try await second.value
        XCTAssertTrue(firstImage === secondImage)
        try await lifetime.beginShutdown().value
    }

    func testCancellingOneConsumerPreservesTheOther() async throws {
        let gate = AsyncTestGate()
        var calls = 0
        let lifetime = ThumbnailLifetime { _ in
            calls += 1
            try await gate.pause()
            return NSImage(size: CGSize(width: 20, height: 20))
        }
        let item = makeItem()
        let first = Task { try await lifetime.load(item) }
        await gate.waitForArrival()
        let second = Task { try await lifetime.load(item) }
        for _ in 0..<10 { await Task.yield() }
        first.cancel()
        for _ in 0..<10 { await Task.yield() }
        await gate.release()
        do { _ = try await first.value; XCTFail("Cancelled consumer received an image") }
        catch is CancellationError { }
        let image = try await second.value
        XCTAssertNotNil(image)
        XCTAssertEqual(calls, 1)
        try await lifetime.beginShutdown().value
    }

    func testChangingSourceWithSameIDDoesNotReuseCachedImage() async throws {
        var calls = 0
        let lifetime = ThumbnailLifetime { _ in
            calls += 1
            return NSImage(size: CGSize(width: calls, height: calls))
        }
        let first = makeItem()
        let replacement = makeItem(id: first.id, path: "/tmp/replaced-thumbnail.png")
        _ = try await lifetime.load(first)
        let image = try await lifetime.load(replacement)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(image?.size.width, 2)
        try await lifetime.beginShutdown().value
    }

    func testLastConsumerCancellationReleasesDecoderAndAllowsNewRequest() async throws {
        let gate = AsyncTestGate()
        var calls = 0
        let lifetime = ThumbnailLifetime { _ in
            calls += 1
            if calls == 1 { try await gate.pause() }
            return NSImage(size: CGSize(width: 20, height: 20))
        }
        let item = makeItem()
        let loading = Task { try await lifetime.load(item) }
        await gate.waitForArrival()
        loading.cancel()
        do { _ = try await loading.value; XCTFail("Cancelled decode succeeded") }
        catch is CancellationError { }
        let image = try await lifetime.load(item)
        XCTAssertNotNil(image)
        XCTAssertEqual(calls, 2)
        try await lifetime.beginShutdown().value
    }

    func testOldSourceCompletingLateCannotReplaceNewCache() async throws {
        let gate = AsyncTestGate()
        let original = makeItem()
        let replacement = makeItem(id: original.id, path: "/tmp/new-thumbnail.png")
        let lifetime = ThumbnailLifetime { item in
            if item.url == original.url { try await gate.pause() }
            return NSImage(size: CGSize(width: item.url == original.url ? 10 : 20, height: 20))
        }
        let old = Task { try await lifetime.load(original) }
        await gate.waitForArrival()
        let new = try await lifetime.load(replacement)
        await gate.release()
        _ = try await old.value
        XCTAssertTrue(lifetime.cachedImage(for: original.id) === new)
        try await lifetime.beginShutdown().value
    }

    func testRenamingAndFavoritingDoNotInvalidateDecodedPixels() async throws {
        var calls = 0
        let lifetime = ThumbnailLifetime { _ in
            calls += 1
            return NSImage(size: CGSize(width: 20, height: 20))
        }
        var item = makeItem()
        let first = try await lifetime.load(item)
        item.customName = "Renamed"; item.isFavorite = true
        let second = try await lifetime.load(item)
        XCTAssertTrue(first === second)
        XCTAssertEqual(calls, 1)
        try await lifetime.beginShutdown().value
    }

    private func makeItem(id: UUID = UUID(), path: String = "/tmp/shared-thumbnail.png") -> MediaItem {
        MediaItem(id: id, url: URL(fileURLWithPath: path), kind: .image, width: 20, height: 20)
    }
}
