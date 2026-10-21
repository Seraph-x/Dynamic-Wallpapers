import AppKit
import AVFoundation
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperScreenshotProducerTests: XCTestCase {
    func testFirstFrameIsAcceptedBeforeStartReturnsAndRequestsArePaced() async throws {
        let frame = try sample()
        var times: [Double] = []
        let stream = makeStream {
            times.append(ProcessInfo.processInfo.systemUptime)
            return frame
        }
        try await stream.start()
        XCTAssertEqual(stream.output.statistics.receivedFrames, 1)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Five paced screenshots") { times.count >= 5 }
        try await stream.beginClose().value
        for (first, second) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(second - first, 0.030, "30 Hz must not burst queued screenshot requests")
        }
        let count = times.count
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(times.count, count)
    }

    func testSlowScreenshotsNeverOverlap() async throws {
        let frame = try sample()
        var active = 0, maximum = 0, requests = 0
        let stream = makeStream {
            requests += 1; active += 1; maximum = max(maximum, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(70))
            return frame
        }
        try await stream.start()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Slow screenshots") { requests >= 3 }
        try await stream.beginClose().value
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(stream.output.statistics.pendingFrames, 0)
    }

    func testFrameRateChangesInBothDirectionsWithoutReplacingTheProducer() async throws {
        let frame = try sample()
        var rate = WallpaperMirrorFrameRate.hz30
        var times: [Double] = []
        let stream = makeStream(frameRate: { rate }) {
            times.append(ProcessInfo.processInfo.systemUptime)
            return frame
        }
        defer { stream.beginClose() }
        try await stream.start()
        var intervals: [Double] = []
        for selection in [WallpaperMirrorFrameRate.hz30, .hz60, .hz30] {
            rate = selection
            let first = times.count + 2 // Let the already-scheduled interval finish.
            try await WallpaperMirrorTestSupport.waitUntil(description: "Changed screenshot cadence") {
                times.count >= first + 8
            }
            let samples = Array(times[first..<(first + 8)])
            let gaps = zip(samples, samples.dropFirst()).map { $1 - $0 }.sorted()
            intervals.append(gaps[gaps.count / 2])
            XCTAssertFalse(stream.isClosed)
        }
        try await stream.beginClose().value
        XCTAssertGreaterThanOrEqual(intervals[0], 0.030)
        XCTAssertGreaterThanOrEqual(intervals[2], 0.030)
        XCTAssertLessThan(intervals[1], intervals[0] * 0.8, "60 Hz must shorten the existing task's cadence")
        XCTAssertGreaterThan(intervals[2], intervals[1] * 1.4, "Switching back must restore 30 Hz")
    }

    func testSixtyHertzStillSerializesSlowScreenshots() async throws {
        let frame = try sample()
        var active = 0, maximum = 0, requests = 0
        let stream = makeStream(frameRate: { .hz60 }) {
            requests += 1; active += 1; maximum = max(maximum, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(45))
            return frame
        }
        defer { stream.beginClose() }
        try await stream.start()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Serial 60 Hz screenshots") { requests >= 4 }
        try await stream.beginClose().value
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(active, 0)
    }

    func testChangingRateDoesNotCancelAnInFlightRequestAndCloseStillRejectsIt() async throws {
        let frame = try sample()
        var rate = WallpaperMirrorFrameRate.hz30
        var requests = 0
        var completion: CheckedContinuation<Void, Error>?
        let entered = expectation(description: "screenshot in flight while changing rate")
        let stream = makeStream(frameRate: { rate }) {
            requests += 1
            if requests == 1 { return frame }
            try await withCheckedThrowingContinuation { completion = $0; entered.fulfill() }
            return frame
        }
        defer { completion?.resume(throwing: CancellationError()); stream.beginClose() }
        try await stream.start()
        await fulfillment(of: [entered], timeout: 1)
        rate = .hz60
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(stream.isClosed)
        let close = stream.beginClose()
        rate = .hz30
        completion?.resume(); completion = nil
        try await close.value
        XCTAssertEqual(stream.output.statistics.receivedFrames, 1)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(requests, 2)
    }

    func testCloseDuringFirstRequestWaitsAndRejectsItsLateFrame() async throws {
        let frame = try sample()
        let entered = expectation(description: "first screenshot pending")
        var completion: CheckedContinuation<Void, Error>?
        let stream = makeStream {
            try await withCheckedThrowingContinuation { completion = $0; entered.fulfill() }
            return frame
        }
        let start = Task { try await stream.start() }
        await fulfillment(of: [entered], timeout: 1)
        let close = stream.beginClose()
        XCTAssertFalse(stream.output.isAcceptingFrames)
        XCTAssertFalse(stream.isClosed)
        completion?.resume(); completion = nil
        do { try await start.value; XCTFail("Closing startup must not succeed") }
        catch is CancellationError { }
        try await close.value
        try await stream.beginClose().value
        XCTAssertTrue(stream.isClosed)
        XCTAssertEqual(stream.output.statistics.receivedFrames, 0)
    }

    func testCloseWaitsForAnInFlightLaterRequestAndStartsNoMore() async throws {
        let frame = try sample()
        let entered = expectation(description: "second screenshot pending")
        var completion: CheckedContinuation<Void, Error>?
        var requests = 0
        let stream = makeStream {
            requests += 1
            if requests == 1 { return frame }
            try await withCheckedThrowingContinuation { completion = $0; entered.fulfill() }
            return frame
        }
        try await stream.start()
        await fulfillment(of: [entered], timeout: 1)
        let close = stream.beginClose()
        XCTAssertFalse(stream.isClosed)
        completion?.resume(); completion = nil
        try await close.value
        XCTAssertEqual(stream.output.statistics.receivedFrames, 1)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(stream.isClosed)
    }

    func testInitialRequestFailureReachesStartAndDoesNotStartTheLoop() async throws {
        var requests = 0
        let stream = makeStream { requests += 1; throw WallpaperError("first screenshot failed") }
        do { try await stream.start(); XCTFail("Initial screenshot failure must be thrown") }
        catch { XCTAssertEqual(error.localizedDescription, "first screenshot failed") }
        try await stream.beginClose().value
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(stream.isClosed)
    }

    func testInvalidFirstBufferCannotAnnounceSuccessfulStartup() async throws {
        let invalid = try sample()
        CMSampleBufferInvalidate(invalid)
        let stream = makeStream { invalid }
        do { try await stream.start(); XCTFail("Invalid pixels cannot make startup succeed") }
        catch { XCTAssertEqual(error.localizedDescription, "全屏壁纸视频帧缺少像素数据。") }
        try await stream.beginClose().value
        XCTAssertEqual(stream.output.statistics.receivedFrames, 0)
    }

    func testRuntimeCancellationErrorIsReportedWhenNoCloseWasRequested() async throws {
        let frame = try sample()
        var requests = 0
        let reported = expectation(description: "unexpected screenshot cancellation reported")
        let stream = makeStream {
            requests += 1
            if requests == 1 { return frame }
            throw CancellationError()
        }
        stream.onFailure = { error in XCTAssertTrue(error is CancellationError); reported.fulfill() }
        try await stream.start()
        await fulfillment(of: [reported], timeout: 1)
        try await stream.beginClose().value
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(stream.output.isAcceptingFrames)
    }

    func testOrdinaryErrorDuringCloseIsNotMistakenForCancellation() async throws {
        try await verifyFailureDuringClose(failingRequest: 2)
    }

    func testOrdinaryFirstRequestErrorDuringCloseIsNotLostWhenStopIsSkipped() async throws {
        try await verifyFailureDuringClose(failingRequest: 1)
    }

    private func verifyFailureDuringClose(failingRequest: Int) async throws {
        let frame = try sample()
        let entered = expectation(description: "failing screenshot pending")
        var completion: CheckedContinuation<CMSampleBuffer, Error>?
        var requests = 0
        let stream = makeStream {
            requests += 1
            if requests < failingRequest { return frame }
            return try await withCheckedThrowingContinuation { completion = $0; entered.fulfill() }
        }
        let start = Task { try await stream.start() }
        await fulfillment(of: [entered], timeout: 1)
        let close = stream.beginClose()
        completion?.resume(throwing: WallpaperError("screenshot failed during close")); completion = nil
        _ = await start.result
        do { try await close.value; XCTFail("A non-cancellation error during close must remain observable") }
        catch { XCTAssertEqual(error.localizedDescription, "screenshot failed during close") }
        XCTAssertEqual(stream.releaseFailure?.localizedDescription, "screenshot failed during close")
        XCTAssertEqual(requests, failingRequest)
    }

    private func makeStream(frameRate: @escaping @MainActor () -> WallpaperMirrorFrameRate = { .hz30 },
                            capture: @escaping @MainActor () async throws -> CMSampleBuffer) -> WallpaperMirrorStream {
        let view = WallpaperMirrorView()
        let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
        let producer = WallpaperScreenshotProducer(output: output, frameRate: frameRate, capture: capture)
        return WallpaperMirrorStream(driver: producer.driver, output: output)
    }

    private func sample() throws -> CMSampleBuffer {
        try WallpaperMirrorTestSupport.sampleBuffer()
    }
}
