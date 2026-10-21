import AppKit
import Combine
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class FullScreenWallpaperMirrorStateTests: XCTestCase {
    func testStreamFactoryRunsOnlyAfterFullScreenActivation() async throws {
        let image = try image()
        let state = FullScreenWallpaperState()
        let captured = expectation(description: "transition image captured")
        var factories = 0
        let session = WallpaperMirrorSession(source: { nil }, systemWallpaper: { image },
                                              changes: Empty().eraseToAnyPublisher())
        state.prepare(mirror: { factories += 1; return session }) { captured.fulfill(); return image }
        await fulfillment(of: [captured], timeout: 1)
        XCTAssertEqual(factories, 0, "A stream created before didEnterFullScreen can stall after the Space transition")
        state.activate()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Mirror displayed") { state.mirror != nil }
        XCTAssertEqual(factories, 1)
        XCTAssertTrue(state.mirror === session)
        state.reset()
        try await state.waitForCleanup()
        XCTAssertTrue(session.isClosed)
    }

    func testExitDuringStreamStartupReleasesLateResultWithoutRestoringTheView() async throws {
        let image = try image()
        let state = FullScreenWallpaperState()
        let window = window()
        defer { window.close() }
        let starting = expectation(description: "stream start pending")
        var completion: CheckedContinuation<Void, Error>?
        let session = WallpaperMirrorSession(source: { WallpaperMirrorSource(window: window) },
            systemWallpaper: { image }, changes: Empty().eraseToAnyPublisher(), makeStream: { _, view in
                self.stream(view: view, start: {
                    try await withCheckedThrowingContinuation { completion = $0; starting.fulfill() }
                })
            })
        state.prepare(mirror: { session }) { image }
        state.activate()
        await fulfillment(of: [starting], timeout: 1)
        state.reset()
        completion?.resume()
        try await state.waitForCleanup()
        XCTAssertTrue(session.isClosed)
        XCTAssertNil(state.mirror)
        XCTAssertNil(state.image)
        XCTAssertNil(state.failure)
    }

    func testRuntimeFailureRemovesTheMirrorAndDoesNotKeepTheFrozenPreparationImage() async throws {
        let image = try image()
        let state = FullScreenWallpaperState()
        let session = WallpaperMirrorSession(source: { nil }, systemWallpaper: { image },
                                              changes: Empty().eraseToAnyPublisher())
        state.prepare(mirror: { session }) { image }
        state.activate()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Mirror displayed") { state.mirror != nil }
        session.onFailure?(WallpaperError("实时采集意外结束"))
        try await state.waitForCleanup()
        XCTAssertNil(state.mirror)
        XCTAssertNil(state.image)
        XCTAssertEqual(state.failure?.summary, "实时采集意外结束")
        XCTAssertTrue(session.isClosed)
    }

    func testCleanupFailureIsVisibleAfterLeavingFullScreen() async throws {
        let image = try image()
        let state = FullScreenWallpaperState()
        let window = window()
        defer { window.close() }
        let session = WallpaperMirrorSession(source: { WallpaperMirrorSource(window: window) },
            systemWallpaper: { image }, changes: Empty().eraseToAnyPublisher(), makeStream: { _, view in
                self.stream(view: view, stop: { throw WallpaperError("采集资源无法关闭") })
            })
        state.prepare(mirror: { session }) { image }
        state.activate()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Mirror displayed") { state.mirror != nil }
        state.reset()
        do { try await state.waitForCleanup(); XCTFail("Cleanup must not fabricate success") }
        catch { XCTAssertEqual(error.localizedDescription, "采集资源无法关闭") }
        try await WallpaperMirrorTestSupport.waitUntil(description: "Cleanup error shown") { state.failure != nil }
        XCTAssertEqual(state.failure?.title, "全屏背景无法关闭")
        XCTAssertEqual(state.failure?.summary, "采集资源无法关闭")
        XCTAssertNil(state.mirror)
        XCTAssertNil(state.image)
    }

    func testRapidReentryWaitsForOldCleanupAndIgnoresItsLateFailure() async throws {
        let image = try image()
        let state = FullScreenWallpaperState()
        let window = window()
        defer { window.close() }
        let stopping = expectation(description: "old stream stopping")
        var completion: CheckedContinuation<Void, Error>?
        let old = WallpaperMirrorSession(source: { WallpaperMirrorSource(window: window) },
            systemWallpaper: { image }, changes: Empty().eraseToAnyPublisher(), makeStream: { _, view in
                self.stream(view: view, stop: {
                    try await withCheckedThrowingContinuation { completion = $0; stopping.fulfill() }
                })
            })
        state.prepare(mirror: { old }) { image }
        state.activate()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Old mirror displayed") { state.mirror === old }
        let lateFailure = old.onFailure
        state.reset()
        let next = WallpaperMirrorSession(source: { nil }, systemWallpaper: { image },
                                         changes: Empty().eraseToAnyPublisher())
        var nextFactories = 0
        state.prepare(mirror: { nextFactories += 1; return next }) { image }
        state.activate()
        await fulfillment(of: [stopping], timeout: 1)
        XCTAssertEqual(nextFactories, 0, "The new stream must wait for the preceding teardown")
        completion?.resume()
        try await WallpaperMirrorTestSupport.waitUntil(description: "New mirror displayed") { state.mirror === next }
        lateFailure?(WallpaperError("old stream error"))
        XCTAssertTrue(old.isClosed)
        XCTAssertEqual(nextFactories, 1)
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.mirror === next)
        state.reset()
        try await state.waitForCleanup()
    }

    func testDetachInvalidatesFramesImmediatelyWithoutPublishingInTheSwiftUIUpdate() async throws {
        let image = try image()
        let state = FullScreenWallpaperState()
        let window = window()
        defer { window.close() }
        var output: WallpaperMirrorFrameOutput?
        let session = WallpaperMirrorSession(source: { WallpaperMirrorSource(window: window) },
            systemWallpaper: { image }, changes: Empty().eraseToAnyPublisher(), makeStream: { _, view in
                let stream = self.stream(view: view)
                output = stream.output
                return stream
            })
        state.prepare(mirror: { session }) { image }
        state.activate()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Mirror displayed") { state.mirror != nil }
        var dismantling = true
        let subscription = state.objectWillChange.sink { XCTAssertFalse(dismantling) }
        state.detach()
        XCTAssertEqual(output?.isAcceptingFrames, false)
        dismantling = false
        try await state.waitForCleanup()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Detached view cleared") { state.mirror == nil }
        XCTAssertTrue(session.isClosed)
        withExtendedLifetime(subscription) {}
    }

    func testFactoryFailureDoesNotLeaveThePreparationImageAsASilentFallback() async throws {
        let image = try image()
        let state = FullScreenWallpaperState()
        state.prepare(mirror: { throw WallpaperError("无法创建实时镜像") }) { image }
        state.activate()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Factory error shown") { state.failure != nil }
        XCTAssertEqual(state.failure?.summary, "无法创建实时镜像")
        XCTAssertNil(state.mirror)
        XCTAssertNil(state.image)
        state.reset()
        try await state.waitForCleanup()
    }

    private func stream(view: WallpaperMirrorView, start: @escaping () async throws -> Void = {},
                        stop: @escaping () async throws -> Void = {}) -> WallpaperMirrorStream {
        WallpaperMirrorStream(driver: WallpaperCaptureDriver(start: start, stop: stop, removeOutput: {}),
                              output: WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer))
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}
