import AppKit
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperMirrorStreamTests: XCTestCase {
    func testCloseDuringStartWaitsThenStopsExactlyOnce() async throws {
        let starting = expectation(description: "system start is pending")
        var completion: CheckedContinuation<Void, Error>?
        var stopCount = 0
        var removeCount = 0
        let view = WallpaperMirrorView()
        let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
        let stream = WallpaperMirrorStream(driver: WallpaperCaptureDriver(start: {
            try await withCheckedThrowingContinuation { completion = $0; starting.fulfill() }
        }, stop: { stopCount += 1 }, removeOutput: { removeCount += 1 }), output: output)
        let start = Task { try await stream.start() }
        await fulfillment(of: [starting], timeout: 1)
        let firstClose = stream.beginClose()
        let secondClose = stream.beginClose()
        XCTAssertFalse(output.isAcceptingFrames, "Closing must reject frames before the system start returns")
        XCTAssertEqual(stopCount, 0, "The system must not receive stop before start completes")
        completion?.resume()
        do { try await start.value; XCTFail("A cancelled startup cannot become active") }
        catch is CancellationError { }
        try await firstClose.value
        try await secondClose.value
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(removeCount, 1)
        XCTAssertTrue(stream.isClosed)
    }

    func testFailedStartIsReportedAndOutputIsReleasedWithoutStoppingAnUnstartedStream() async throws {
        var stopCount = 0
        var removeCount = 0
        let view = WallpaperMirrorView()
        let stream = WallpaperMirrorStream(driver: WallpaperCaptureDriver(
            start: { throw WallpaperError("capture start failed") }, stop: { stopCount += 1 },
            removeOutput: { removeCount += 1 }),
            output: WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer))
        do { try await stream.start(); XCTFail("Start failure must reach the caller") }
        catch { XCTAssertEqual(error.localizedDescription, "capture start failed") }
        try await stream.beginClose().value
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(removeCount, 1)
        XCTAssertTrue(stream.isClosed)
    }

    func testSystemStopConfirmationIsNotLostWhenCloseBeginsBeforeTheCallback() async throws {
        var redundantStops = 0
        let view = WallpaperMirrorView()
        let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
        let stream = WallpaperMirrorStream(driver: WallpaperCaptureDriver(start: {},
            stop: { redundantStops += 1; throw WallpaperError("system capture already stopped") }, removeOutput: {}),
            output: output)
        try await stream.start()
        output.captureDidStop(WallpaperError("system stop confirmation"))
        let close = stream.beginClose()
        do { try await close.value }
        catch { XCTFail("An already confirmed system stop must not be requested again: \(error)") }
        XCTAssertEqual(redundantStops, 0)
        XCTAssertTrue(stream.isClosed)
    }

    func testStopFailureRemainsObservableAndDoesNotClaimTheStreamWasReleased() async throws {
        var stopCount = 0
        var removeCount = 0
        let view = WallpaperMirrorView()
        let stream = WallpaperMirrorStream(driver: WallpaperCaptureDriver(start: {}, stop: {
            stopCount += 1
            throw WallpaperError("capture stop failed")
        }, removeOutput: { removeCount += 1 }),
            output: WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer))
        try await stream.start()
        for _ in 0..<2 {
            do { try await stream.beginClose().value; XCTFail("Stop failure must remain visible") }
            catch { XCTAssertEqual(error.localizedDescription, "capture stop failed") }
        }
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(removeCount, 0, "Keep ownership of a stream whose stop was not confirmed")
        XCTAssertFalse(stream.isClosed)
        XCTAssertEqual(stream.releaseFailure?.localizedDescription, "capture stop failed")
    }
}
