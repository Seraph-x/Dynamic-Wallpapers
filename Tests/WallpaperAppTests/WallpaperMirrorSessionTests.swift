import AppKit
import Combine
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperMirrorSessionTests: XCTestCase {
    func testOldSourceReleaseDoesNotWaitForReplacementStartup() async throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        var source = WallpaperMirrorSource(window: first)
        let changes = PassthroughSubject<Void, Never>()
        let image = try image()
        let starting = expectation(description: "replacement startup pending")
        let released = expectation(description: "old capture released independently")
        var completion: CheckedContinuation<Void, Never>?
        var oldStopped = false
        let session = WallpaperMirrorSession(source: { source }, systemWallpaper: { image },
            changes: changes.eraseToAnyPublisher(), makeStream: { window, view in
                if window === first { return self.stream(view: view, stop: { oldStopped = true }) }
                return self.stream(view: view, start: {
                    await withCheckedContinuation { completion = $0; starting.fulfill() }
                })
            })
        try await session.start(initialImage: image)
        source = WallpaperMirrorSource(window: second)
        changes.send()
        let releaseBarrier = session.sourceReleaseBarrier()
        await fulfillment(of: [starting], timeout: 1)
        XCTAssertTrue(oldStopped)
        let releasing = Task { try await releaseBarrier?.value; released.fulfill() }
        await fulfillment(of: [released], timeout: 0.3)
        completion?.resume(); completion = nil
        try await releasing.value
        try await session.waitForUpdates()
        try await session.beginClose().value
    }

    func testNewSourceFailureIsNotReportedAsOldSourceReleaseFailure() async throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        var source = WallpaperMirrorSource(window: first)
        let changes = PassthroughSubject<Void, Never>()
        let image = try image()
        let session = WallpaperMirrorSession(source: { source }, systemWallpaper: { image },
            changes: changes.eraseToAnyPublisher(), makeStream: { window, view in
                self.stream(view: view, start: {
                    if window === second { throw WallpaperError("replacement failed") }
                })
            })
        try await session.start(initialImage: image)
        source = WallpaperMirrorSource(window: second)
        changes.send()
        let releaseBarrier = session.sourceReleaseBarrier()
        do { try await session.waitForUpdates(); XCTFail("Replacement must fail") }
        catch { XCTAssertEqual(error.localizedDescription, "replacement failed") }
        do { try await releaseBarrier?.value }
        catch { XCTFail("The old source was released successfully: \(error)") }
        XCTAssertEqual(session.failure?.localizedDescription, "replacement failed", "Keep the real startup failure visible")
        try await session.beginClose().value
    }

    func testSourceReplacementRemovalAndReappearanceReleaseEachOldStream() async throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        var source: WallpaperMirrorSource? = WallpaperMirrorSource(window: first)
        let changes = PassthroughSubject<Void, Never>()
        let image = try image()
        var events: [String] = []
        let session = WallpaperMirrorSession(source: { source }, systemWallpaper: { image },
            changes: changes.eraseToAnyPublisher(), makeStream: { window, view in
                let name = window === first ? "first" : "second"
                return self.stream(view: view, start: { events.append("start-\(name)") },
                                   stop: { events.append("stop-\(name)") })
            })
        try await session.start(initialImage: image)
        source = WallpaperMirrorSource(window: second)
        changes.send()
        try await session.waitForUpdates()
        source = nil
        changes.send()
        try await session.waitForUpdates()
        XCTAssertTrue(session.view.layer?.contents as AnyObject? === image)
        source = WallpaperMirrorSource(window: first)
        changes.send()
        try await session.waitForUpdates()
        try await session.beginClose().value
        XCTAssertEqual(events, ["start-first", "stop-first", "start-second", "stop-second", "start-first", "stop-first"])
        XCTAssertNil(session.view.layer?.contents)
        XCTAssertTrue(session.isClosed)
    }

    func testCloseWaitsForLateFactoryResultAndNeverStartsIt() async throws {
        let window = window()
        defer { window.close() }
        let creating = expectation(description: "capture factory pending")
        var completion: CheckedContinuation<WallpaperMirrorStream, Error>?
        var created: WallpaperMirrorStream?
        var starts = 0
        let image = try image()
        let session = WallpaperMirrorSession(source: { WallpaperMirrorSource(window: window) },
            systemWallpaper: { image }, changes: Empty().eraseToAnyPublisher(), makeStream: { _, view in
                created = self.stream(view: view, start: { starts += 1 })
                return try await withCheckedThrowingContinuation { completion = $0; creating.fulfill() }
            })
        let start = Task { try await session.start(initialImage: image) }
        await fulfillment(of: [creating], timeout: 1)
        let close = session.beginClose()
        XCTAssertFalse(session.isClosed)
        completion?.resume(returning: try XCTUnwrap(created))
        do { try await start.value; XCTFail("A closed background must not become ready") }
        catch is CancellationError { }
        try await close.value
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(try XCTUnwrap(created).isClosed)
        XCTAssertTrue(session.isClosed)
    }

    func testRapidSourceChangeWaitsForOldStartupAndRelease() async throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let starting = expectation(description: "first stream starting")
        var completion: CheckedContinuation<Void, Error>?
        var source: WallpaperMirrorSource? = WallpaperMirrorSource(window: first)
        var events: [String] = []
        let image = try image()
        let changes = PassthroughSubject<Void, Never>()
        let session = WallpaperMirrorSession(source: { source }, systemWallpaper: { image },
            changes: changes.eraseToAnyPublisher(), makeStream: { window, view in
                if window === first {
                    return self.stream(view: view, start: {
                        events.append("start-first")
                        try await withCheckedThrowingContinuation { completion = $0; starting.fulfill() }
                    }, stop: { events.append("stop-first") })
                }
                return self.stream(view: view, start: { events.append("start-second") })
            })
        let start = Task { try await session.start(initialImage: image) }
        await fulfillment(of: [starting], timeout: 1)
        source = WallpaperMirrorSource(window: second)
        changes.send()
        XCTAssertEqual(events, ["start-first"])
        completion?.resume()
        try await start.value
        try await session.waitForUpdates()
        XCTAssertEqual(events, ["start-first", "stop-first", "start-second"])
        try await session.beginClose().value
    }

    func testFailedReleasePreventsAReplacementAndRemainsVisibleOnClose() async throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        var source: WallpaperMirrorSource? = WallpaperMirrorSource(window: first)
        let image = try image()
        let changes = PassthroughSubject<Void, Never>()
        var starts = 0
        var failures: [String] = []
        let session = WallpaperMirrorSession(source: { source }, systemWallpaper: { image },
            changes: changes.eraseToAnyPublisher(), makeStream: { _, view in
                self.stream(view: view, start: { starts += 1 }, stop: { throw WallpaperError("old stream did not stop") })
            })
        session.onFailure = { failures.append($0.localizedDescription) }
        try await session.start(initialImage: image)
        source = WallpaperMirrorSource(window: second)
        changes.send()
        do { try await session.waitForUpdates(); XCTFail("Cannot replace an unreleased stream") }
        catch { XCTAssertEqual(error.localizedDescription, "old stream did not stop") }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(failures, ["old stream did not stop"])
        do { try await session.beginClose().value; XCTFail("Close failure must reach the owner") }
        catch { XCTAssertEqual(error.localizedDescription, "old stream did not stop") }
        XCTAssertFalse(session.isClosed)
    }

    func testSupersededFactoryFailureDoesNotPoisonTheNewSource() async throws {
        try await verifySupersededFailure(duringFactory: true)
    }

    func testSupersededStartFailureDoesNotPoisonTheNewSource() async throws {
        try await verifySupersededFailure(duringFactory: false)
    }

    private func verifySupersededFailure(duringFactory: Bool) async throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let pending = expectation(description: "old operation pending")
        var completion: CheckedContinuation<Void, Error>?
        var source = WallpaperMirrorSource(window: first)
        var starts: [String] = []
        var failures: [String] = []
        let image = try image()
        let changes = PassthroughSubject<Void, Never>()
        let delayed: () async throws -> Void = {
            try await withCheckedThrowingContinuation { completion = $0; pending.fulfill() }
        }
        let session = WallpaperMirrorSession(source: { source }, systemWallpaper: { image },
            changes: changes.eraseToAnyPublisher(), makeStream: { window, view in
                if window === first {
                    if duringFactory { try await delayed() }
                    return self.stream(view: view, start: {
                        starts.append("first")
                        if !duringFactory { try await delayed() }
                    })
                }
                return self.stream(view: view, start: { starts.append("second") })
            })
        session.onFailure = { failures.append($0.localizedDescription) }
        let start = Task { try await session.start(initialImage: image) }
        await fulfillment(of: [pending], timeout: 1)
        source = WallpaperMirrorSource(window: second)
        changes.send()
        completion?.resume(throwing: WallpaperError("superseded operation failed"))
        let result = await start.result
        try await session.beginClose().value
        if case .failure(let error) = result { XCTFail("A stale error blocked the new source: \(error)") }
        XCTAssertEqual(starts, duringFactory ? ["second"] : ["first", "second"])
        XCTAssertNil(session.failure)
        XCTAssertTrue(failures.isEmpty)
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func stream(view: WallpaperMirrorView, start: @escaping () async throws -> Void = {},
                        stop: @escaping () async throws -> Void = {}) -> WallpaperMirrorStream {
        WallpaperMirrorStream(driver: WallpaperCaptureDriver(start: start, stop: stop, removeOutput: {}),
                              output: WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer))
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}
