import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class WebSurfaceTests: XCTestCase {
    private let item = MediaItem(url: URL(fileURLWithPath: "/project/index.html"), kind: .web,
        width: 640, height: 360, backend: .web,
        webProject: WebProjectReference(root: URL(fileURLWithPath: "/project"), entry: "index.html"))

    private func fixture() -> (WebSurface, ControlledWebFactory) {
        let factory = ControlledWebFactory()
        return (WebSurface(size: CGSize(width: 320, height: 180), fit: .fit, pageFactory: factory), factory)
    }

    func testClickRequiresTheCurrentPlayingPageAcrossPauseAndReload() async throws {
        let (surface, factory) = fixture()
        XCTAssertNil(surface.interactivePageID)
        try await surface.prepare(item: item, scale: 2, fit: .fit)
        XCTAssertNil(surface.interactivePageID, "Preloaded pages must not accept input")
        surface.play()
        let firstID = try XCTUnwrap(surface.interactivePageID)
        XCTAssertTrue(try surface.sendClick(at: CGPoint(x: 80, y: 45), clickCount: 2, expectedPageID: firstID))
        XCTAssertEqual(factory.pages[0].clicks.count, 1)
        XCTAssertEqual(factory.pages[0].clicks[0].0, CGPoint(x: 80, y: 45), "CEF takes logical points, not Retina pixels")
        XCTAssertEqual(factory.pages[0].clicks[0].1, 2)
        surface.pause()
        XCTAssertNil(surface.interactivePageID)
        XCTAssertThrowsError(try surface.sendClick(at: .zero, clickCount: 1, expectedPageID: firstID))
        try await surface.prepareToResume()
        XCTAssertNil(surface.interactivePageID)
        surface.play()
        let nextID = try XCTUnwrap(surface.interactivePageID)
        XCTAssertNotEqual(nextID, firstID)
        XCTAssertThrowsError(try surface.sendClick(at: .zero, clickCount: 1, expectedPageID: firstID))
        XCTAssertTrue(try surface.sendClick(at: CGPoint(x: 40, y: 20), clickCount: 1, expectedPageID: nextID))
        XCTAssertEqual(factory.pages[0].clicks.count, 1)
        XCTAssertEqual(factory.pages[1].clicks.count, 1)
        try await surface.close()
        XCTAssertNil(surface.interactivePageID)
    }

    func testClickMappingMatchesVisibleFitAndFillContent() async throws {
        for fit in [ContentFit.fit, .fill] {
            let (surface, factory) = fixture()
            try await surface.prepare(item: item, scale: 2, fit: fit)
            surface.play()
            let id = try XCTUnwrap(surface.interactivePageID)
            surface.setFrameSize(CGSize(width: 720, height: 180))
            let delivered = try surface.sendClick(at: CGPoint(x: 0, y: 0), clickCount: 1, expectedPageID: id)
            if fit == .fit {
                XCTAssertFalse(delivered, "Letterbox clicks must explicitly report no delivery")
                XCTAssertTrue(factory.pages[0].clicks.isEmpty)
            } else {
                XCTAssertTrue(delivered)
                XCTAssertEqual(factory.pages[0].clicks.last?.0, CGPoint(x: 0, y: 50))
            }
            XCTAssertTrue(try surface.sendClick(at: CGPoint(x: 360, y: 90), clickCount: 1, expectedPageID: id))
            XCTAssertEqual(factory.pages[0].clicks.last?.0, CGPoint(x: 160, y: 90))
            XCTAssertThrowsError(try surface.sendClick(at: CGPoint(x: CGFloat.nan, y: 0), clickCount: 1, expectedPageID: id))
            XCTAssertThrowsError(try surface.sendClick(at: .zero, clickCount: 0, expectedPageID: id))
            try await surface.close()
        }
    }

    func testPreparationWaitsForPageAndAudioIsPlayingGated() async throws {
        let (surface, factory) = fixture()
        factory.holdPrepare = true
        surface.setGlobalMute(false)
        surface.setAudio(AudioSettings(volume: 0.8))
        surface.setTransitionGain(0.25)
        let preparation = Task { try await surface.prepare(item: item, scale: 2, fit: .fill) }
        await fulfillment(of: [factory.created], timeout: 1)
        let page = try XCTUnwrap(factory.pages.first)
        await fulfillment(of: [page.prepareStarted], timeout: 1)
        XCTAssertEqual(surface.state, .preparing)
        XCTAssertEqual(page.gains.last, 0)
        XCTAssertEqual(factory.sizes, [CGSize(width: 320, height: 180)])
        XCTAssertEqual(page.scale, 2)
        page.finishPrepare()
        try await preparation.value
        XCTAssertEqual(surface.state, .ready)
        XCTAssertTrue(page.view.superview === surface.view)
        XCTAssertEqual(page.gains.last, 0)
        surface.play()
        XCTAssertEqual(page.gains.last ?? -1, 0.2, accuracy: 0.0001)
        surface.setAudioSuppressed(true)
        XCTAssertEqual(page.gains.last, 0)
        surface.setAudioSuppressed(false)
        surface.setGlobalMute(true)
        XCTAssertEqual(page.gains.last, 0)
        try await surface.close()
    }

    func testPauseClosesBeforeSingleReloadAndKeepsFrame() async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        surface.setGlobalMute(false)
        surface.play()
        let first = factory.pages[0]
        first.holdClose = true
        let lateError = first.onError
        surface.pause()
        XCTAssertEqual(first.gains.last, 0)
        XCTAssertEqual(surface.state, .pausing)
        surface.play(); surface.play()
        await fulfillment(of: [first.closeStarted], timeout: 1)
        XCTAssertEqual(factory.pages.count, 1)
        XCTAssertTrue(first.view.superview === surface.view)
        first.finishClose()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(factory.pages.count, 2)
        XCTAssertEqual(surface.state, .playing)
        lateError?(WallpaperError("old generation"))
        XCTAssertEqual(surface.state, .playing)
        try await surface.close()
    }

    func testPrepareToResumeReloadsSilentlyUntilBarrierPlay() async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        surface.setGlobalMute(false)
        surface.play(); surface.pause()
        let pausedView = surface.subviews.first
        try await surface.prepareToResume()
        XCTAssertEqual(factory.pages.count, 2)
        XCTAssertEqual(surface.state, .ready)
        XCTAssertEqual(factory.pages[1].gains.last, 0)
        XCTAssertTrue(surface.subviews.first === pausedView, "Group preparation must not replace the paused frame before commit")
        surface.play()
        XCTAssertTrue(surface.subviews.first === factory.pages[1].view)
        XCTAssertEqual(factory.pages[1].gains.last, 1)
        try await surface.close()
    }

    func testRevokedReadyResumeRetainsPausedFrameAndClosesNewPage() async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        let pausedView = surface.subviews.first
        surface.play(); surface.pause()
        try await surface.prepareToResume()
        try await surface.cancelResumePreparation()
        XCTAssertTrue(surface.subviews.first === pausedView)
        XCTAssertEqual(factory.pages[1].closeCalls, 1)
        XCTAssertEqual(factory.activePages, 0)
        XCTAssertEqual(surface.state, .paused)
        try await surface.close()
    }

    func testLatestPlayDuringCancelledReloadStartsOneReplacement() async throws {
        try await checkLatestPlayAfterCancelledReload(groupResume: false, cancelRequest: false)
    }

    func testSupersededGroupResumeDoesNotCancelLatestPlay() async throws {
        try await checkLatestPlayAfterCancelledReload(groupResume: true, cancelRequest: false)
    }

    func testCancellingSupersededGroupResumeDoesNotCancelLatestPlay() async throws {
        try await checkLatestPlayAfterCancelledReload(groupResume: true, cancelRequest: true)
    }

    func testNewResumeRequestOwnsSharedReloadAfterEarlierRequestCancelled() async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        surface.pause()
        factory.holdPrepare = true
        let secondCreated = expectation(description: "shared reload created")
        factory.onCreated = { _, count in if count == 2 { secondCreated.fulfill() } }
        let first = Task { try await surface.prepareToResume() }
        await fulfillment(of: [secondCreated], timeout: 1)
        let pending = factory.pages[1]
        await fulfillment(of: [pending.prepareStarted], timeout: 1)
        let newerStarted = expectation(description: "newer request entered")
        let newer = Task {
            newerStarted.fulfill()
            try await surface.prepareToResume()
        }
        await fulfillment(of: [newerStarted], timeout: 1)
        first.cancel()
        pending.finishPrepare()
        do { try await first.value; XCTFail("Superseded request succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected superseded error: \(error)") }
        try await newer.value
        XCTAssertEqual(surface.state, .ready)
        XCTAssertEqual(factory.pages.count, 2)
        XCTAssertEqual(pending.closeCalls, 0)
        XCTAssertTrue(pending.gains.allSatisfy { $0 == 0 })
        try await surface.close()
    }

    private func checkLatestPlayAfterCancelledReload(groupResume: Bool, cancelRequest: Bool) async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        surface.setGlobalMute(false)
        surface.play()
        let secondCreated = expectation(description: "second page created")
        let replacementPlaying = expectation(description: "replacement page playing")
        factory.holdPrepare = true
        factory.onCreated = { page, count in
            if count == 2 { secondCreated.fulfill() }
            if count == 3 {
                page.onGain = { gain in
                    if gain > 0 { replacementPlaying.fulfill() }
                }
            }
        }
        surface.pause()
        let resume: Task<Void, Error>?
        if groupResume { resume = Task { try await surface.prepareToResume() } }
        else { resume = nil; surface.play() }
        await fulfillment(of: [secondCreated], timeout: 1)
        let second = try XCTUnwrap(factory.pages.dropFirst().first)
        await fulfillment(of: [second.prepareStarted], timeout: 1)
        second.holdClose = true
        surface.pause()
        // The old reload task is still suspended in second.prepare here.
        surface.play()
        if cancelRequest { resume?.cancel() }
        await fulfillment(of: [second.closeStarted], timeout: 1)
        XCTAssertEqual(factory.pages.count, 2)
        XCTAssertEqual(second.gains.last, 0)
        factory.holdPrepare = false
        second.finishClose()
        if let resume {
            do { try await resume.value; XCTFail("Superseded resume reported success") }
            catch is CancellationError {} catch { XCTFail("Unexpected superseded resume error: \(error)") }
        }
        await fulfillment(of: [replacementPlaying], timeout: 1)
        XCTAssertEqual(factory.pages.count, 3)
        XCTAssertEqual(factory.maximumActivePages, 1, "Reload must wait for the previous page release")
        XCTAssertEqual(surface.state, .playing, "The final play intent must survive cancelled reload completion")
        try await surface.close()
        XCTAssertEqual(factory.activePages, 0)
    }

    func testCloseFailureRemainsOwnedAndNeverReloads() async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        let failure = NSError(domain: "WebSurfaceTests", code: 42)
        factory.pages[0].closeFailure = failure
        surface.pause()
        await fulfillment(of: [factory.pages[0].closeStarted], timeout: 1)
        for _ in 0..<10 { await Task.yield() }
        surface.play()
        for _ in 0..<10 { await Task.yield() }
        for _ in 0..<2 {
            do { try await surface.close(); XCTFail("Failed close reported success") }
            catch { XCTAssertTrue((error as NSError) === failure) }
        }
        XCTAssertEqual(factory.pages.count, 1)
        XCTAssertEqual(factory.pages[0].closeCalls, 1)
        XCTAssertEqual(surface.state, .failed)
    }

    func testRuntimeErrorHostPauseClosesPageAndRetainsFailureFrame() async throws {
        try await checkRuntimeErrorHostPause(closeFails: false)
    }

    func testRuntimeErrorHostPauseRetainsSlotWhenCloseFails() async throws {
        try await checkRuntimeErrorHostPause(closeFails: true)
    }

    private func checkRuntimeErrorHostPause(closeFails: Bool) async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        surface.setGlobalMute(false)
        surface.play()
        let page = factory.pages[0]
        let failure = NSError(domain: "WebSurfaceRuntimeError", code: 1)
        let closingFailure = NSError(domain: "WebSurfaceCloseError", code: 2)
        if closeFails { page.closeFailure = closingFailure }
        var errors: [NSError] = []
        surface.onError = { error in
            errors.append(error as NSError)
            surface.pause()  // Desktop host pauses after reporting a backend error.
        }
        page.onError?(failure)
        XCTAssertEqual(page.gains.last, 0)
        await fulfillment(of: [page.closeStarted], timeout: 1)
        XCTAssertEqual(page.closeCalls, 1)
        XCTAssertTrue(page.view.superview === surface.view, "Failure must keep the last displayable frame")
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first === failure, "Resource cleanup must not replace the original reported error")
        surface.play()
        XCTAssertEqual(factory.pages.count, 1)
        XCTAssertEqual(surface.state, .failed)
        if closeFails {
            XCTAssertEqual(factory.activePages, 1)
            do { try await surface.close(); XCTFail("Failed close reported success") }
            catch { XCTAssertTrue((error as NSError) === closingFailure) }
            XCTAssertEqual(factory.activePages, 1)
        } else {
            XCTAssertEqual(factory.activePages, 0)
            try await surface.close()
        }
        XCTAssertEqual(page.closeCalls, 1)
        XCTAssertEqual(errors.count, 1)
        surface.onError = nil
    }

    func testAlreadyCancelledResumeRejectsReadyFastPath() async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        let resume = Task { try await surface.prepareToResume() }
        resume.cancel()
        do { try await resume.value; XCTFail("An already-cancelled resume reported success") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertEqual(factory.pages.count, 1)
        XCTAssertEqual(factory.pages[0].gains.last, 0)
        XCTAssertEqual(factory.pages[0].closeCalls, 1)
        XCTAssertEqual(factory.activePages, 0, "Cancelled ready page must be released before cancellation completes")
        XCTAssertEqual(surface.state, .paused)
        try await surface.close()
    }

    func testCancellationDuringResumeClosesPendingPageBeforeReturning() async throws {
        let (surface, factory) = fixture()
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        surface.setGlobalMute(false)
        surface.play(); surface.pause()
        factory.holdPrepare = true
        let secondCreated = expectation(description: "pending resume page created")
        factory.onCreated = { _, count in if count == 2 { secondCreated.fulfill() } }
        let resume = Task { try await surface.prepareToResume() }
        await fulfillment(of: [secondCreated], timeout: 1)
        let pending = try XCTUnwrap(factory.pages.dropFirst().first)
        await fulfillment(of: [pending.prepareStarted], timeout: 1)
        pending.holdClose = true
        resume.cancel()
        await fulfillment(of: [pending.closeStarted], timeout: 1)
        XCTAssertEqual(pending.gains.last, 0)
        XCTAssertEqual(factory.pages.count, 2)
        pending.finishClose()
        do { try await resume.value; XCTFail("Cancelled pending resume reported success") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertEqual(pending.closeCalls, 1)
        XCTAssertEqual(factory.activePages, 0)
        XCTAssertEqual(surface.state, .paused)
        XCTAssertTrue(pending.gains.allSatisfy { $0 == 0 }, "Cancelled reload must never open output")
        try await surface.close()
    }

    func testCloseDuringPreparationCannotResurrect() async throws {
        let (surface, factory) = fixture()
        factory.holdPrepare = true
        let preparation = Task { try await surface.prepare(item: item, scale: 1, fit: .fit) }
        await fulfillment(of: [factory.created], timeout: 1)
        let page = factory.pages[0]
        await fulfillment(of: [page.prepareStarted], timeout: 1)
        let closing = Task { try await surface.close() }
        await fulfillment(of: [page.closeStarted], timeout: 1)
        page.finishPrepare()
        do { try await preparation.value; XCTFail("Closed generation became ready") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        try await closing.value
        surface.play()
        XCTAssertEqual(surface.state, .closed)
        XCTAssertEqual(factory.pages.count, 1)
        XCTAssertEqual(page.gains.last, 0)
    }

    func testCloseWaitsForInitialPrepareMethodToExit() async throws {
        try await checkCloseWaitsForPrepareExit()
    }

    private func checkCloseWaitsForPrepareExit() async throws {
        let (surface, factory) = fixture()
        factory.holdPrepare = true
        factory.holdPrepareExit = true
        let preparation = Task<Void, Error> {
            try await surface.prepare(item: item, scale: 1, fit: .fit)
            return ()
        }
        await fulfillment(of: [factory.created], timeout: 1)
        let page = factory.pages[0]
        await fulfillment(of: [page.prepareStarted], timeout: 1)
        var closeReturned = false
        let closing = Task<Void, Error> {
            try await surface.close()
            closeReturned = true
            return ()
        }
        await fulfillment(of: [page.prepareExitStarted], timeout: 1)
        XCTAssertEqual(page.closeCalls, 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(closeReturned, "Surface close returned before prepare exited")
        page.finishPrepareExit()
        do { try await preparation.value; XCTFail("Closed preparation reported success") }
        catch is CancellationError {} catch { XCTFail("Unexpected prepare error: \(error)") }
        try await closing.value
        XCTAssertTrue(closeReturned)
        XCTAssertEqual(surface.state, .closed)
    }
}

@MainActor
private final class ControlledWebFactory: WebPageMaking {
    var pages: [ControlledWebPage] = []
    var sizes: [CGSize] = []
    var holdPrepare = false
    var holdPrepareExit = false
    var onCreated: ((ControlledWebPage, Int) -> Void)?
    private(set) var activePages = 0
    private(set) var maximumActivePages = 0
    let created = XCTestExpectation(description: "page created")
    func makePage(size: CGSize) throws -> any WebPageSession {
        let page = ControlledWebPage()
        page.holdPrepare = holdPrepare
        page.holdPrepareExit = holdPrepareExit
        activePages += 1
        maximumActivePages = max(maximumActivePages, activePages)
        page.onClosed = { [weak self] in self?.activePages -= 1 }
        sizes.append(size); pages.append(page)
        onCreated?(page, pages.count)
        if pages.count == 1 { created.fulfill() }
        return page
    }
}

@MainActor
private final class ControlledWebPage: WebPageSession {
    let view = NSView()
    var onError: ((Error) -> Void)?
    var gains: [Double] = []
    var clicks: [(CGPoint, Int)] = []
    var scale: CGFloat?
    var holdPrepare = false
    var holdPrepareExit = false
    var holdClose = false
    var closeFailure: Error?
    var closeCalls = 0
    var onGain: ((Double) -> Void)?
    var onClosed: (() -> Void)?
    let prepareStarted = XCTestExpectation(description: "prepare started")
    let closeStarted = XCTestExpectation(description: "close started")
    let prepareExitStarted = XCTestExpectation(description: "prepare exit blocked")
    private var preparing: CheckedContinuation<Void, Never>?
    private var closing: CheckedContinuation<Void, Never>?
    private var prepareExit: CheckedContinuation<Void, Never>?
    func prepare(project: WebProjectReference, scale: CGFloat) async throws {
        self.scale = scale
        prepareStarted.fulfill()
        if holdPrepare { await withCheckedContinuation { preparing = $0 } }
        if holdPrepareExit {
            prepareExitStarted.fulfill()
            await withCheckedContinuation { prepareExit = $0 }
        }
    }
    func setGain(_ linearGain: Double) throws { gains.append(linearGain); onGain?(linearGain) }
    func sendClick(at point: CGPoint, clickCount: Int) throws { clicks.append((point, clickCount)) }
    func close() async throws {
        closeCalls += 1
        closeStarted.fulfill()
        if holdClose { await withCheckedContinuation { closing = $0 } }
        if let closeFailure { throw closeFailure }
        onClosed?()
        onClosed = nil
        finishPrepare()
    }
    func finishPrepare() { preparing?.resume(); preparing = nil }
    func finishClose() { closing?.resume(); closing = nil }
    func finishPrepareExit() { prepareExit?.resume(); prepareExit = nil }
}
