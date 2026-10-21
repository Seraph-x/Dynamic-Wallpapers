import AppKit
import AVFoundation
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperMirrorFrameOutputTests: XCTestCase {
    func testCaptureConfigurationUsesNativePixelsAndNoAudioCursorOrShadow() throws {
        let config = try WallpaperMirrorStream.configuration(size: CGSize(width: 1440, height: 900), scale: 2)
        XCTAssertEqual(config.width, 2880)
        XCTAssertEqual(config.height, 1800)
        XCTAssertEqual(config.minimumFrameInterval, .zero)
        XCTAssertFalse(config.capturesAudio)
        XCTAssertFalse(config.showsCursor)
        XCTAssertTrue(config.ignoreShadowsSingleWindow)
        XCTAssertTrue(config.ignoreGlobalClipSingleWindow)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_32BGRA)
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 1), CGSize(width: -1, height: 1)] {
            XCTAssertThrowsError(try WallpaperMirrorStream.configuration(size: size, scale: 2))
        }
    }

    func testInvalidFrameReportsOneFailureAndStopsAcceptingFrames() async throws {
        let view = WallpaperMirrorView()
        let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
        let reported = expectation(description: "invalid frame reported")
        var errors: [String] = []
        output.onFailure = { error, stopped in
            errors.append(error.localizedDescription)
            XCTAssertFalse(stopped)
            reported.fulfill()
        }
        let frame = try sample()
        CMSampleBufferInvalidate(frame)
        output.receive(frame)
        output.receive(frame)
        await fulfillment(of: [reported], timeout: 1)
        XCTAssertFalse(output.isAcceptingFrames)
        XCTAssertEqual(errors, ["全屏壁纸视频帧缺少像素数据。"])
        await output.finish()
        XCTAssertEqual(output.statistics.pendingFrames, 0)
    }

    func testBackpressureKeepsOnlyTheLatestPendingFrameAndCloseRejectsLateFrames() async throws {
        let view = WallpaperMirrorView()
        let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
        let frame = try sample()
        var maximumPending = 0
        for _ in 0..<1000 {
            output.receive(frame)
            maximumPending = max(maximumPending, output.statistics.pendingFrames)
        }
        XCTAssertEqual(output.statistics.receivedFrames, 1000)
        XCTAssertGreaterThan(output.statistics.replacedFrames, 0, "The test must actually exercise renderer backpressure")
        XCTAssertLessThanOrEqual(maximumPending, 1)
        output.invalidate()
        let received = output.statistics.receivedFrames
        output.receive(frame)
        await output.finish()
        XCTAssertEqual(output.statistics.receivedFrames, received)
        XCTAssertEqual(output.statistics.pendingFrames, 0)
        XCTAssertFalse(output.isAcceptingFrames)
    }

    func testFinishWaitsForQueuedCallbacks() async throws {
        let view = WallpaperMirrorView()
        let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
        let entered = expectation(description: "capture callback entered")
        let finishing = expectation(description: "finish called")
        let premature = expectation(description: "finish must not complete before its queue drains")
        premature.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        output.queue.async { entered.fulfill(); gate.wait() }
        let task = Task { finishing.fulfill(); await output.finish(); premature.fulfill() }
        await fulfillment(of: [entered, finishing], timeout: 1)
        await fulfillment(of: [premature], timeout: 0.05)
        gate.signal()
        await task.value
        XCTAssertFalse(output.isAcceptingFrames)
    }

    private func sample() throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
        let buffer = try XCTUnwrap(image)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
