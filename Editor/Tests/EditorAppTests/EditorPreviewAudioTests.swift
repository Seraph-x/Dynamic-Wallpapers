import AppKit
import XCTest
import WallpaperCore
import WallpaperAudioSpectrum
@testable import EditorApp

@MainActor final class EditorCaptureFixture: SystemAudioCapturing {
    var starts = 0, stops = 0
    var startError: Error?, stopError: Error?, snapshotError: Error?
    var holdStart = false
    var startReply: CheckedContinuation<Void, Error>?
    var onStart: (() -> Void)?
    var spectrum = AudioSpectrum(left: Array(repeating: 0.6, count: 64), right: Array(repeating: 0.2, count: 64))
    func start() async throws {
        starts += 1; onStart?()
        if holdStart { try await withCheckedThrowingContinuation { startReply = $0 } }
        if let startError { throw startError }
    }
    func snapshot() throws -> AudioSpectrum { if let snapshotError { throw snapshotError }; return spectrum }
    func stop() async throws { stops += 1; if let stopError { throw stopError } }
}

@MainActor final class EditorPreviewAudioTests: XCTestCase {
    private var domains: [String] = []
    private func preferences() -> UserDefaults {
        let name = "EditorPreviewAudioTests.\(UUID())"; domains.append(name)
        return UserDefaults(suiteName: name)!
    }
    override func tearDown() { for domain in domains { UserDefaults().removePersistentDomain(forName: domain) }; super.tearDown() }
    private func owner(_ capture: EditorCaptureFixture, defaults: UserDefaults? = nil, supported: Bool = true) -> EditorPreviewAudioController {
        EditorPreviewAudioController(controller: SystemAudioSpectrumController(supported: supported, makeCapture: { capture }), defaults: defaults ?? preferences())
    }

    func testDefaultOffAndEnabledWithoutDemandNeverStartCapture() async throws {
        let capture = EditorCaptureFixture()
        let audio = owner(capture)
        XCTAssertFalse(audio.enabled); XCTAssertEqual(audio.status, .disabled)
        audio.setEnabled(true); await audio.settled()
        XCTAssertEqual(audio.status, .waiting)
        XCTAssertEqual(capture.starts, 0)
        try await audio.shutdown()
    }

    func testEditorPreferenceIsSeparatePersistentAndExplicitBooleanOnly() async throws {
        let defaults = preferences(), capture = EditorCaptureFixture()
        defaults.set(true, forKey: "systemAudioSpectrumEnabled") // Main's setting is never read.
        let audio = owner(capture, defaults: defaults)
        XCTAssertFalse(audio.enabled)
        audio.setEnabled(true)
        let reloaded = owner(EditorCaptureFixture(), defaults: defaults)
        XCTAssertTrue(reloaded.enabled)
        try await audio.shutdown(); try await reloaded.shutdown()
        for malformed: Any in [1, 0, "true", "false", [true]] {
            defaults.removeObject(forKey: EditorPreviewAudioController.preferenceKey)
            defaults.set(malformed, forKey: EditorPreviewAudioController.preferenceKey)
            let invalid = owner(EditorCaptureFixture(), defaults: defaults)
            XCTAssertFalse(invalid.enabled); XCTAssertEqual(invalid.status, .failed)
            XCTAssertNotNil(invalid.failure)
            invalid.retry(); XCTAssertNotNil(invalid.failure)
            invalid.setEnabled(false); XCTAssertNil(invalid.failure)
            try await invalid.shutdown()
        }
    }

    func testMultiplePreviewMembersShareOneCaptureAndLastRemovalStops() async throws {
        let capture = EditorCaptureFixture(), audio = owner(capture), first = UUID(), second = UUID()
        var values: [AudioSpectrum] = []
        audio.setEnabled(true)
        audio.addSubscriber(id: first, deliver: { values.append($0) }, onFailure: { XCTFail("\($0)") })
        audio.addSubscriber(id: second, deliver: { _ in }, onFailure: { XCTFail("\($0)") })
        await audio.settled(); XCTAssertEqual(capture.starts, 1)
        audio.removeSubscriber(id: first); await audio.settled()
        XCTAssertEqual(capture.stops, 0); XCTAssertEqual(values.last, .zero)
        audio.removeSubscriber(id: second); await audio.settled()
        XCTAssertEqual(capture.stops, 1); XCTAssertEqual(audio.status, .waiting)
        try await audio.shutdown()
    }

    func testDisableDuringPendingStartReleasesTheOwnedCapture() async throws {
        let capture = EditorCaptureFixture(); capture.holdStart = true
        let audio = owner(capture), began = expectation(description: "Capture start pending")
        capture.onStart = { began.fulfill() }
        audio.setEnabled(true); audio.addSubscriber(id: UUID(), deliver: { _ in }, onFailure: { XCTFail("\($0)") })
        await fulfillment(of: [began], timeout: 2)
        audio.setEnabled(false); capture.startReply?.resume(); await audio.settled()
        XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(audio.status, .disabled)
        try await audio.shutdown()
    }

    func testCaptureFailureStaysVisibleUntilExplicitRetryAndRetainsFailedRelease() async throws {
        let capture = EditorCaptureFixture(); capture.startError = WallpaperError("OS start denied")
        capture.stopError = WallpaperError("OS cleanup failed")
        let audio = owner(capture), id = UUID()
        audio.setEnabled(true); audio.addSubscriber(id: id, deliver: { _ in }, onFailure: { XCTFail("\($0)") })
        await audio.settled(); XCTAssertEqual(audio.status, .failed); XCTAssertNotNil(audio.failure)
        audio.removeSubscriber(id: id)
        audio.addSubscriber(id: id, deliver: { _ in }, onFailure: { XCTFail("\($0)") })
        await audio.settled(); XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 1)
        do { try await audio.shutdown(); XCTFail("Release error hidden") } catch {}
        XCTAssertEqual(audio.status, .failed)
        capture.startError = nil; capture.stopError = nil
        try await audio.shutdown(); XCTAssertEqual(capture.stops, 3)
    }

    func testExplicitRetryRestartsOnlyAfterFailure() async throws {
        let capture = EditorCaptureFixture(); capture.startError = WallpaperError("OS permission denied")
        let audio = owner(capture)
        audio.setEnabled(true); audio.addSubscriber(id: UUID(), deliver: { _ in }, onFailure: { XCTFail("\($0)") })
        await audio.settled(); XCTAssertEqual(capture.starts, 1); XCTAssertEqual(audio.status, .failed)
        capture.startError = nil; audio.retry(); await audio.settled()
        XCTAssertEqual(capture.starts, 2); XCTAssertEqual(audio.status, .capturing)
        XCTAssertNil(audio.failure); try await audio.shutdown()
    }

    func testDeliveryFailureRemovesOnlyFailedPageAndExposesError() async throws {
        let capture = EditorCaptureFixture(), audio = owner(capture), bad = UUID(), good = UUID()
        var errors = 0, delivered = 0
        audio.setEnabled(true)
        audio.addSubscriber(id: bad, deliver: { _ in throw WallpaperError("Page endpoint failed") }, onFailure: { _ in errors += 1 })
        audio.addSubscriber(id: good, deliver: { _ in delivered += 1 }, onFailure: { XCTFail("\($0)") })
        await audio.settled()
        XCTAssertEqual(errors, 1); XCTAssertEqual(capture.starts, 1)
        let tick = expectation(description: "Real controller sampling timer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { tick.fulfill() }
        await fulfillment(of: [tick], timeout: 2)
        XCTAssertGreaterThan(delivered, 1); XCTAssertEqual(errors, 1)
        audio.removeSubscriber(id: good); await audio.settled(); XCTAssertEqual(capture.stops, 1)
        try await audio.shutdown()
    }

    func testRetryAfterRemovingMalformedPreferenceRestoresDefaultOff() async throws {
        let defaults = preferences(), capture = EditorCaptureFixture()
        defaults.set("malformed", forKey: EditorPreviewAudioController.preferenceKey)
        let audio = owner(capture, defaults: defaults)
        XCTAssertEqual(audio.status, .failed)
        defaults.removeObject(forKey: EditorPreviewAudioController.preferenceKey)
        audio.retry(); await audio.settled()
        XCTAssertFalse(audio.enabled); XCTAssertEqual(audio.status, .disabled)
        XCTAssertNil(audio.failure); XCTAssertEqual(capture.starts, 0)
        try await audio.shutdown()
    }

    func testFailedShutdownCancelKeepsFailureAndExplicitRetryReleasesOwnedCapture() async throws {
        let capture = EditorCaptureFixture(), audio = owner(capture)
        audio.setEnabled(true); audio.addSubscriber(id: UUID(), deliver: { _ in }, onFailure: { XCTFail("\($0)") })
        await audio.settled(); capture.stopError = WallpaperError("OS release denied")
        do { try await audio.shutdown(); XCTFail("Release failure hidden") } catch {}
        XCTAssertTrue(audio.shuttingDown); XCTAssertEqual(audio.status, .failed)
        audio.cancelShutdown(); XCTAssertFalse(audio.shuttingDown)
        XCTAssertNotNil(audio.failure); XCTAssertEqual(capture.stops, 1)
        capture.stopError = nil; audio.retry(); await audio.settled()
        XCTAssertEqual(capture.stops, 2); XCTAssertEqual(audio.status, .waiting)
        XCTAssertNil(audio.failure); XCTAssertEqual(capture.starts, 1)
        try await audio.shutdown()
    }

    func testCompletedShutdownCancelAllowsFuturePreviewDemand() async throws {
        let capture = EditorCaptureFixture(), audio = owner(capture)
        audio.setEnabled(true); try await audio.shutdown()
        XCTAssertTrue(audio.shuttingDown); audio.cancelShutdown()
        audio.addSubscriber(id: UUID(), deliver: { _ in }, onFailure: { XCTFail("\($0)") })
        await audio.settled(); XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(audio.status, .capturing); try await audio.shutdown()
    }

    func testUnsupportedExplicitlyDisablesCapture() async throws {
        let capture = EditorCaptureFixture(), audio = owner(capture, supported: false)
        audio.setEnabled(true); audio.addSubscriber(id: UUID(), deliver: { _ in }, onFailure: { XCTFail("\($0)") })
        await audio.settled(); XCTAssertEqual(audio.status, .unsupported); XCTAssertFalse(audio.supported)
        XCTAssertEqual(capture.starts, 0); try await audio.shutdown()
    }
}
