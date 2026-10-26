import AppKit
import XCTest
import WallpaperCore
import WallpaperAudioSpectrum
@testable import EditorApp

@MainActor final class EditorScenePreviewAudioTests: XCTestCase {
    private var domains: [String] = []
    private func owner(_ capture: EditorCaptureFixture) -> EditorPreviewAudioController {
        let domain = "EditorScenePreviewAudioTests.\(UUID())"; domains.append(domain)
        let audio = EditorPreviewAudioController(controller: SystemAudioSpectrumController(supported: true, makeCapture: { capture }), defaults: UserDefaults(suiteName: domain)!)
        audio.setEnabled(true); return audio
    }
    override func tearDown() { for domain in domains { UserDefaults().removePersistentDomain(forName: domain) }; super.tearDown() }
    private func ready(_ page: PreviewPageFixture, _ session: EditorScenePreviewSession) async {
        page.onReady?()
        for _ in 0..<50 { if session.state != .loading { return }; await Task.yield() }
        XCTFail("Native play acknowledgement did not finish")
    }

    func testNoCaptureUntilReadyAndSuccessfulPlayAckThenPauseResumeClose() async throws {
        let capture = EditorCaptureFixture(), page = PreviewPageFixture(), audio = owner(capture)
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: {})
        try session.start(); await audio.settled(); XCTAssertEqual(capture.starts, 0)
        page.holdPlaying = true; page.onReady?()
        for _ in 0..<20 { await Task.yield() }
        await audio.settled(); XCTAssertEqual(capture.starts, 0)
        page.playReply?.resume(); page.holdPlaying = false
        for _ in 0..<20 { await Task.yield() }
        await audio.settled(); XCTAssertEqual(capture.starts, 1); XCTAssertEqual(session.state, .playing)
        try await session.setPlaying(false); await audio.settled()
        XCTAssertEqual(capture.stops, 1); XCTAssertEqual(page.spectra.last, .zero)
        try await session.setPlaying(true); await audio.settled(); XCTAssertEqual(capture.starts, 2)
        try await session.close(); await audio.settled(); XCTAssertEqual(capture.stops, 2)
        try await audio.shutdown()
    }

    func testCloseBeforeLateInitialAckDoesNotSubscribeOrResurrectSession() async throws {
        let capture = EditorCaptureFixture(), page = PreviewPageFixture(), audio = owner(capture)
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: {})
        page.holdPlaying = true; try session.start(); page.onReady?()
        for _ in 0..<20 { await Task.yield() }
        try await session.close(); page.playReply?.resume()
        for _ in 0..<20 { await Task.yield() }
        await audio.settled(); XCTAssertEqual(capture.starts, 0); XCTAssertEqual(session.state, .closed)
        try await audio.shutdown()
    }

    func testOldAckAfterRestartCannotSubscribeSamePageObjectIntoNewGeneration() async throws {
        let capture = EditorCaptureFixture(), page = PreviewPageFixture(), audio = owner(capture)
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: {})
        page.holdPlaying = true; try session.start(); page.onReady?()
        for _ in 0..<20 { await Task.yield() }
        let obsoleteReply = page.playReply
        try await session.restart(); obsoleteReply?.resume()
        for _ in 0..<20 { await Task.yield() }
        await audio.settled(); XCTAssertEqual(capture.starts, 0); XCTAssertEqual(session.state, .loading)
        page.holdPlaying = false; await ready(page, session); await audio.settled()
        XCTAssertEqual(capture.starts, 1); try await session.close(); try await audio.shutdown()
    }

    func testFailedReadyPlayAckNeverSubscribesAndExplicitRestartCanRecover() async throws {
        let capture = EditorCaptureFixture(), page = PreviewPageFixture(), audio = owner(capture)
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: {})
        page.playError = WallpaperError("Play ACK rejected")
        try session.start(); await ready(page, session); await audio.settled()
        XCTAssertEqual(session.state, .failed); XCTAssertNotNil(session.failure); XCTAssertEqual(capture.starts, 0)
        page.playError = nil; try await session.restart(); await ready(page, session); await audio.settled()
        XCTAssertEqual(capture.starts, 1); try await session.close(); try await audio.shutdown()
    }

    func testTwoSessionsPendingCaptureStartKeepsOnlyRemainingPlayingDemand() async throws {
        let capture = EditorCaptureFixture(); capture.holdStart = true
        let audio = owner(capture), first = PreviewPageFixture(), second = PreviewPageFixture()
        let a = EditorScenePreviewSession(makePage: { first }, audio: audio, cleanup: {})
        let b = EditorScenePreviewSession(makePage: { second }, audio: audio, cleanup: {})
        let began = expectation(description: "Pending OS start"); capture.onStart = { began.fulfill() }
        try a.start(); await ready(first, a); await fulfillment(of: [began], timeout: 2)
        try b.start(); await ready(second, b); try await a.close()
        capture.startReply?.resume(); await audio.settled()
        XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 0)
        XCTAssertEqual(a.state, .closed); XCTAssertEqual(b.state, .playing)
        try await b.close(); await audio.settled(); XCTAssertEqual(capture.stops, 1)
        try await audio.shutdown()
    }

    func testCaptureSamplingFailureZerosPageButDoesNotFailScene() async throws {
        let capture = EditorCaptureFixture(), page = PreviewPageFixture(), audio = owner(capture)
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: {})
        try session.start(); await ready(page, session); await audio.settled()
        capture.snapshotError = WallpaperError("OS stream lost")
        let sampled = expectation(description: "Sampling failure")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { sampled.fulfill() }
        await fulfillment(of: [sampled], timeout: 2); await audio.settled()
        XCTAssertEqual(audio.status, .failed); XCTAssertEqual(page.spectra.last, .zero)
        XCTAssertEqual(session.state, .playing); XCTAssertNil(session.failure)
        try await session.close(); try await audio.shutdown()
    }

    func testPageDeliveryFailureIsVisibleAndRetiresItsCaptureDemand() async throws {
        let capture = EditorCaptureFixture(), page = PreviewPageFixture(), audio = owner(capture)
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: {})
        page.spectrumError = WallpaperError("Native endpoint delivery failed")
        try session.start(); await ready(page, session); await audio.settled()
        XCTAssertEqual(session.state, .failed); XCTAssertNotNil(session.failure)
        XCTAssertEqual(capture.starts, 0)
        page.spectrumError = nil; try await session.close(); try await audio.shutdown()
    }

    func testSceneFailureRetainsRootErrorAndZeroDeliveryFailure() async throws {
        let capture = EditorCaptureFixture(), page = PreviewPageFixture(), audio = owner(capture)
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: {})
        try session.start(); await ready(page, session); await audio.settled()
        page.spectrumError = WallpaperError("Zero endpoint failed")
        page.onError?(WallpaperError("Root scene failure"))
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(session.failure?.localizedDescription.contains("Root scene failure") == true)
        XCTAssertTrue(session.failure?.localizedDescription.contains("Zero endpoint failed") == true)
        page.spectrumError = nil; try await session.close(); try await audio.shutdown()
    }

    func testCloseZeroDeliveryFailureRemainsVisibleAndSnapshotCleanupRequiresRetry() async throws {
        let capture = EditorCaptureFixture(), page = PreviewPageFixture(), audio = owner(capture)
        var cleanups = 0
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: { cleanups += 1 })
        try session.start(); await ready(page, session); await audio.settled()
        page.spectrumError = WallpaperError("Zero endpoint failed")
        do { try await session.close(); XCTFail("Zero delivery failure hidden") } catch {}
        XCTAssertEqual(session.state, .failed); XCTAssertNotNil(session.failure)
        XCTAssertEqual(cleanups, 0); XCTAssertTrue(page.closed)
        try await session.close(); XCTAssertEqual(cleanups, 1)
        try await audio.shutdown()
    }

    func testSampledStereoReachesBothPagesAndPauseZerosBeforeNativeCommand() async throws {
        let capture = EditorCaptureFixture(), first = PreviewPageFixture(), second = PreviewPageFixture(), audio = owner(capture)
        let a = EditorScenePreviewSession(makePage: { first }, audio: audio, cleanup: {})
        let b = EditorScenePreviewSession(makePage: { second }, audio: audio, cleanup: {})
        try a.start(); await ready(first, a); try b.start(); await ready(second, b); await audio.settled()
        let sampled = expectation(description: "Controller stereo delivery")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { sampled.fulfill() }
        await fulfillment(of: [sampled], timeout: 2)
        XCTAssertEqual(first.spectra.last, capture.spectrum); XCTAssertEqual(second.spectra.last, capture.spectrum)
        first.onPlay = { XCTAssertEqual(first.spectra.last, .zero, "Pause must zero data before native ACK") }
        try await a.setPlaying(false); await audio.settled()
        XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 0)
        try await a.close(); try await b.close(); await audio.settled()
        XCTAssertEqual(capture.stops, 1); try await audio.shutdown()
    }

    func testNativeWindowsObserveOneSwitchAndExposeLocalizedOSFailure() async throws {
        _ = NSApplication.shared
        let capture = EditorCaptureFixture(), audio = owner(capture)
        let page = PreviewPageFixture()
        let session = EditorScenePreviewSession(makePage: { page }, audio: audio, cleanup: {})
        let otherSession = EditorScenePreviewSession(makePage: { PreviewPageFixture() }, audio: audio, cleanup: {})
        let first = EditorScenePreviewWindowController(session: session, title: "First")
        let second = EditorScenePreviewWindowController(session: otherSession, title: "Second")
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        func toggle(_ controller: EditorScenePreviewWindowController) throws -> NSButton {
            try XCTUnwrap(children(try XCTUnwrap(controller.window?.contentView)).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "editor-system-audio-toggle" })
        }
        let firstToggle = try toggle(first), secondToggle = try toggle(second)
        XCTAssertEqual(firstToggle.state, .on); XCTAssertEqual(secondToggle.state, .on)
        firstToggle.performClick(nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(audio.enabled); XCTAssertEqual(secondToggle.state, .off)
        secondToggle.performClick(nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(audio.enabled); XCTAssertEqual(firstToggle.state, .on)
        capture.startError = WallpaperError("OSStatus -1234: capture denied")
        try session.start(); await ready(page, session); await audio.settled()
        for _ in 0..<20 { await Task.yield() }
        let controls = children(try XCTUnwrap(first.window?.contentView))
        let status = try XCTUnwrap(controls.compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "editor-system-audio-status" })
        XCTAssertTrue(status.string.contains(text("previewAudioFailed")))
        XCTAssertTrue(status.string.contains("OSStatus -1234: capture denied"))
        let retry = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "editor-system-audio-retry" })
        XCTAssertFalse(retry.isHidden); XCTAssertTrue(retry.isEnabled)
        try await first.requestClose(); try await second.requestClose(); try await audio.shutdown()
    }

    func testNativeAudioControlsAreSharedTranslatedAndFitBothAppearances() async throws {
        _ = NSApplication.shared
        let capture = EditorCaptureFixture(), audio = owner(capture)
        let resources = try EditorNativeScenePreviewPage.runtimeDirectory().deletingLastPathComponent()
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        for language in ["en", "zh-Hans", "ja", "fr", "es"] {
            let bundle = try XCTUnwrap(Bundle(path: resources.appendingPathComponent(language + ".lproj").path))
            let t: (String) -> String = { bundle.localizedString(forKey: $0, value: nil, table: nil) }
            let session = EditorScenePreviewSession(makePage: { PreviewPageFixture() }, audio: audio, cleanup: {})
            let windowController = EditorScenePreviewWindowController(session: session, title: "Audio layout", localize: t)
            let window = try XCTUnwrap(windowController.window), content = try XCTUnwrap(window.contentView)
            window.setFrame(NSRect(origin: .zero, size: window.minSize), display: false)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance); content.layoutSubtreeIfNeeded()
                let controls = children(content)
                let toggle = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "editor-system-audio-toggle" })
                XCTAssertEqual(toggle.title, t("previewAudioEnabled")); XCTAssertNotEqual(toggle.title, "previewAudioEnabled")
                XCTAssertEqual(toggle.state, .on)
                let retry = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "editor-system-audio-retry" })
                XCTAssertEqual(retry.title, t("previewAudioRetry")); XCTAssertTrue(retry.isHidden)
                XCTAssertTrue(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == t("previewAudioDisclosure") })
                let footer = try XCTUnwrap(controls.compactMap { $0 as? NSScrollView }.first { $0.identifier?.rawValue == "editor-preview-footer-scroll" })
                XCTAssertGreaterThan(try XCTUnwrap(footer.documentView).bounds.height, footer.contentView.bounds.height)
                let visible = controls.filter { !$0.isHidden && ($0 is NSButton || $0 is NSTextField || $0 is NSScrollView) }
                for view in visible {
                    view.scrollToVisible(view.bounds); content.layoutSubtreeIfNeeded()
                    let frame = view.convert(view.bounds, to: content)
                    XCTAssertGreaterThanOrEqual(frame.minX, -1, language); XCTAssertGreaterThanOrEqual(frame.minY, -1, language)
                    XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width + 1, language)
                    XCTAssertLessThanOrEqual(frame.maxY, content.bounds.height + 1, language)
                }
            }
            try await windowController.requestClose()
        }
        XCTAssertEqual(capture.starts, 0); try await audio.shutdown()
    }
}
