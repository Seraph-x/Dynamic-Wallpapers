import XCTest
@testable import WallpaperApp

@MainActor
final class SystemAudioSpectrumControllerTests: XCTestCase {
    final class Capture: SystemAudioCapturing {
        var starts = 0, stops = 0
        var startFailure: Error?, stopFailure: Error?, pollFailure: Error?
        var starting: CheckedContinuation<Void, Error>?
        var holdStart = false
        func start() async throws {
            starts += 1
            if let startFailure { throw startFailure }
            if holdStart { try await withCheckedThrowingContinuation { starting = $0 } }
        }
        func stop() async throws { stops += 1; if let stopFailure { throw stopFailure } }
        func snapshot() throws -> AudioSpectrum {
            if let pollFailure { throw pollFailure }
            return AudioSpectrum(left: [Float](repeating: 0.5, count: 64), right: [Float](repeating: 0.25, count: 64))
        }
    }
    struct Failure: Error {}

    func testNewSubscriberDuringPendingStartKeepsOneCapture() async throws {
        let capture = Capture(); capture.holdStart = true
        let controller = SystemAudioSpectrumController(supported: true, makeCapture: { capture })
        controller.setEnabled(true); controller.setPlaying(UUID(), true)
        while capture.starting == nil { await Task.yield() }
        controller.setPlaying(UUID(), true)
        capture.holdStart = false
        capture.starting?.resume(); capture.starting = nil
        await controller.settled()
        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(capture.stops, 0)
        try await controller.shutdown()
    }

    func testDefaultOffAndSharedCaptureDemand() async throws {
        let capture = Capture()
        let controller = SystemAudioSpectrumController(supported: true, makeCapture: { capture })
        let a = UUID(), b = UUID()
        controller.setPlaying(a, true)
        await controller.settled()
        XCTAssertEqual(capture.starts, 0)
        controller.setEnabled(true)
        await controller.settled()
        controller.setPlaying(b, true)
        await controller.settled()
        XCTAssertEqual(capture.starts, 1)
        controller.setPlaying(a, false)
        await controller.settled()
        XCTAssertEqual(capture.stops, 0)
        controller.setPlaying(b, false)
        await controller.settled()
        XCTAssertEqual(capture.stops, 1)
        try await controller.shutdown()
    }

    func testDisableDuringStartCannotPublishOrLeakCapture() async throws {
        let capture = Capture(); capture.holdStart = true
        let controller = SystemAudioSpectrumController(supported: true, makeCapture: { capture })
        var nonzero = false
        controller.onSpectrum = { if $0 != .zero { nonzero = true } }
        controller.setEnabled(true); controller.setPlaying(UUID(), true)
        while capture.starting == nil { await Task.yield() }
        controller.setEnabled(false)
        capture.starting?.resume(); capture.starting = nil
        await controller.settled()
        XCTAssertFalse(nonzero)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(controller.status, .disabled)
        try await controller.shutdown()
    }

    func testFailureIsVisibleAndRetryIsExplicit() async throws {
        let capture = Capture(); capture.startFailure = Failure()
        let controller = SystemAudioSpectrumController(supported: true, makeCapture: { capture })
        controller.setEnabled(true); controller.setPlaying(UUID(), true)
        await controller.settled()
        XCTAssertNotNil(controller.failure)
        capture.startFailure = nil
        controller.setPlaying(UUID(), true)
        await controller.settled()
        XCTAssertEqual(capture.starts, 1, "New demand must not hide a failed capture by retrying")
        controller.retry()
        await controller.settled()
        XCTAssertNil(controller.failure)
        XCTAssertEqual(capture.starts, 2)
        try await controller.shutdown()
    }

    func testStopFailureRetainsOwnerForExplicitRetry() async throws {
        let capture = Capture()
        let controller = SystemAudioSpectrumController(supported: true, makeCapture: { capture })
        controller.setEnabled(true); controller.setPlaying(UUID(), true)
        await controller.settled()
        capture.stopFailure = Failure()
        controller.setEnabled(false)
        await controller.settled()
        XCTAssertNotNil(controller.failure)
        capture.stopFailure = nil
        try await controller.shutdown()
        XCTAssertEqual(capture.stops, 2)
    }

    func testUnsupportedSystemNeverCreatesCapture() async throws {
        var creations = 0
        let controller = SystemAudioSpectrumController(supported: false, makeCapture: { creations += 1; return Capture() })
        controller.setEnabled(true); controller.setPlaying(UUID(), true)
        await controller.settled()
        XCTAssertEqual(controller.status, .unsupported)
        XCTAssertEqual(creations, 0)
        try await controller.shutdown()
    }

    func testCaptureFailureClearsSpectrumAndStopsWithoutRetrying() async throws {
        let capture = Capture()
        let controller = SystemAudioSpectrumController(supported: true, makeCapture: { capture })
        var last = AudioSpectrum.zero
        controller.onSpectrum = { last = $0 }
        controller.setEnabled(true); controller.setPlaying(UUID(), true)
        await controller.settled()
        let deadline = ContinuousClock.now + .seconds(2)
        while last == .zero, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotEqual(last, .zero)
        capture.pollFailure = Failure()
        while controller.failure == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await controller.settled()
        XCTAssertNotNil(controller.failure)
        XCTAssertEqual(last, .zero)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(capture.starts, 1)
        try await controller.shutdown()
    }
}
