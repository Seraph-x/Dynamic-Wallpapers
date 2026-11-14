import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ThumbnailLifetimeTests: XCTestCase {
    func testCachedThumbnailAvoidsAnotherDecode() async throws {
        var loads = 0
        let lifetime = ThumbnailLifetime { _ in
            loads += 1
            return NSImage(size: CGSize(width: 480, height: 270))
        }
        let item = makeItem()
        let first = try await lifetime.load(item)
        let second = try await lifetime.load(item)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertEqual(loads, 1)
        try await lifetime.beginShutdown().value
    }

    func testShutdownReleasesCachedThumbnails() async throws {
        let lifetime = ThumbnailLifetime { _ in NSImage(size: CGSize(width: 480, height: 270)) }
        let item = makeItem()
        weak var image: NSImage?
        image = try await lifetime.load(item)
        XCTAssertNotNil(image)

        try await lifetime.beginShutdown().value

        XCTAssertNil(lifetime.cachedImage(for: item.id))
        XCTAssertNil(image)
    }

    func testRemovingMediaEvictsOnlyItsThumbnail() async throws {
        let lifetime = ThumbnailLifetime { _ in NSImage(size: CGSize(width: 480, height: 270)) }
        let removed = makeItem(), retained = makeItem()
        _ = try await lifetime.load(removed)
        _ = try await lifetime.load(retained)

        try await lifetime.beginRemovingMedia([removed.id]).value

        XCTAssertNil(lifetime.cachedImage(for: removed.id))
        XCTAssertNotNil(lifetime.cachedImage(for: retained.id))
        do {
            _ = try await lifetime.load(removed)
            XCTFail("Removed media must not be reopened")
        } catch is CancellationError { }
        try await lifetime.beginShutdown().value
    }

    func testLateDecodeDoesNotRepopulateCacheAfterShutdown() async throws {
        let started = expectation(description: "decoder started")
        var finish: CheckedContinuation<NSImage?, Never>?
        let lifetime = ThumbnailLifetime { _ in
            await withCheckedContinuation { finish = $0; started.fulfill() }
        }
        let item = makeItem()
        let loading = Task { try await lifetime.load(item) }
        await fulfillment(of: [started], timeout: 1)
        let shutdown = lifetime.beginShutdown()
        finish?.resume(returning: NSImage(size: CGSize(width: 480, height: 270)))
        _ = await loading.result
        try await shutdown.value

        XCTAssertNil(lifetime.cachedImage(for: item.id))
    }

    func testDecodeFailureIsReportedAndCanBeRetried() async throws {
        struct DecodeFailure: Error {}
        var loads = 0
        let lifetime = ThumbnailLifetime { _ in
            loads += 1
            if loads == 1 { throw DecodeFailure() }
            return NSImage(size: CGSize(width: 480, height: 270))
        }
        let item = makeItem()
        do {
            _ = try await lifetime.load(item)
            XCTFail("Decode failure must propagate")
        } catch is DecodeFailure { }
        XCTAssertNil(lifetime.cachedImage(for: item.id))
        let retried = try await lifetime.load(item)
        XCTAssertNotNil(retried)
        XCTAssertEqual(loads, 2)
        try await lifetime.beginShutdown().value
    }

    func testLateDecodeDoesNotRepopulateRemovedMedia() async throws {
        let started = expectation(description: "decoder started")
        var finish: CheckedContinuation<NSImage?, Never>?
        let lifetime = ThumbnailLifetime { _ in
            await withCheckedContinuation { finish = $0; started.fulfill() }
        }
        let item = makeItem()
        let loading = Task { try await lifetime.load(item) }
        await fulfillment(of: [started], timeout: 1)
        let removal = lifetime.beginRemovingMedia([item.id])
        finish?.resume(returning: NSImage(size: CGSize(width: 480, height: 270)))
        _ = await loading.result
        try await removal.value

        XCTAssertNil(lifetime.cachedImage(for: item.id))
        try await lifetime.beginShutdown().value
    }

    func testLargeLibraryThumbnailsRemainLoadableAcrossEvictions() async throws {
        let lifetime = ThumbnailLifetime { _ in
            try autoreleasepool {
                let pixels = try XCTUnwrap(CGContext(data: nil, width: 480, height: 270,
                    bitsPerComponent: 8, bytesPerRow: 480 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                pixels.setFillColor(NSColor.blue.cgColor)
                pixels.fill(CGRect(x: 0, y: 0, width: 480, height: 270))
                return NSImage(cgImage: try XCTUnwrap(pixels.makeImage()), size: .zero)
            }
        }
        let items = (0..<160).map { _ in makeItem() }
        for item in items {
            let image = try await lifetime.load(item)
            XCTAssertEqual(image?.size, CGSize(width: 480, height: 270))
        }
        let retained = items.filter { lifetime.cachedImage(for: $0.id) != nil }.count
        print("THUMBNAIL_CACHE_WORKLOAD loaded=\(items.count) retained=\(retained) pixelBytes=\(retained * 480 * 270 * 4)")
        // Eviction is advisory: test successful reloads, not a particular NSCache order or count.
        for item in items.prefix(10) {
            let image = try await lifetime.load(item)
            XCTAssertEqual(image?.size, CGSize(width: 480, height: 270))
        }
        try await lifetime.beginShutdown().value
    }

    private func makeItem() -> MediaItem {
        MediaItem(url: URL(fileURLWithPath: "/tmp/thumbnail.png"), kind: .image,
                  width: 480, height: 270)
    }
}
