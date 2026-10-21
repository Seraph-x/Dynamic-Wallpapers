@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class R3RetirementTests: XCTestCase {
    private let item = MediaItem(url: URL(fileURLWithPath: "/retirement/index.html"), kind: .web,
        width: 32, height: 32, backend: .web,
        webProject: WebProjectReference(root: URL(fileURLWithPath: "/retirement"), entry: "index.html"))

    func testSuccessfullyResumedSurfaceDeallocatesAfterRetirement() async throws {
        _ = NSApplication.shared
        let factory = WeakRetirementFactory()
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main), surfaceFactory: factory)
        defer { window.shutdown() }
        try await displayAndResume(window)
        weak let retired = factory.latest
        XCTAssertNotNil(retired)
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        let result = await window.transition(duration: 0, paused: false)
        XCTAssertTrue(result.didDisplay)
        XCTAssertNil(result.error)
        try await window.waitForClosing()
        XCTAssertEqual(window.activeSurfaceCount, 1)
        XCTAssertNil(retired, "Successful retirement must release the resumed WebSurface and its retained frame")
        window.shutdown()
        try await window.waitForClosing()
    }

    func testFailedRetirementRetainsSurfaceSlotAndCloseError() async throws {
        _ = NSApplication.shared
        let factory = WeakRetirementFactory()
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main), surfaceFactory: factory)
        defer { window.shutdown() }
        try await displayAndResume(window)
        weak let retired = factory.latest
        factory.pages.latest?.closeError = WallpaperError("retirement close failed")
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        let result = await window.transition(duration: 0, paused: false)
        XCTAssertTrue(result.didDisplay)
        XCTAssertEqual(result.error?.localizedDescription, "retirement close failed")
        do { try await window.waitForClosing(); XCTFail("Close failure must remain observable") }
        catch { XCTAssertEqual(error.localizedDescription, "retirement close failed") }
        XCTAssertNotNil(retired)
        XCTAssertEqual(retired?.state, .failed)
        XCTAssertEqual(window.activeSurfaceCount, 2)
        XCTAssertNotNil(window.releaseFailure)
        window.shutdown()
        do { try await window.waitForClosing(); XCTFail("Shutdown must preserve the close failure") }
        catch { XCTAssertEqual(error.localizedDescription, "retirement close failed") }
    }

    private func displayAndResume(_ window: DesktopWindow) async throws {
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        let result = await window.transition(duration: 0, paused: false)
        XCTAssertTrue(result.didDisplay)
        window.setPaused(true)
        try await window.prepareToResume(requestID: UUID())
        window.setPaused(false)
    }

    func testGroupDoesNotReportFailureOrRestartWhileResumeCleanupIsSuspended() async throws {
        let ready = HeldCleanupEndpoint(), bad = HeldCleanupEndpoint()
        let entry = PlaylistEntry(mediaID: item.id)
        let committed = expectation(description: "initial display")
        var failures = 0
        let session = PlaybackSession(playlist: Playlist(name: "cleanup", entries: [entry], transition: 0),
            media: [item], endpoints: [ready, bad], fit: .fit, autoAdvance: false,
            onCommit: { _ in committed.fulfill() }, onStatus: { _ in }, onError: { _ in failures += 1 })
        defer { ready.releaseCleanup(); session.stop() }
        session.start()
        await fulfillment(of: [committed], timeout: 1)
        session.setPaused(true)
        ready.holdCleanup = true
        bad.resumeError = WallpaperError("peer prepare failed")
        session.setPaused(false)
        await fulfillment(of: [ready.cleanupStarted], timeout: 1)
        XCTAssertEqual(ready.ownedResumes, 1)
        session.setPaused(true)
        session.setPaused(false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(failures, 0, "Failure delivery must wait until peer cleanup completes")
        XCTAssertEqual(ready.resumeCalls, 1, "A replacement resume must wait for old cleanup")
        XCTAssertEqual(ready.playCalls, 0)
        let restarted = expectation(description: "replacement resume starts after cleanup")
        ready.onResume = { restarted.fulfill() }
        bad.resumeError = nil
        ready.releaseCleanup()
        await fulfillment(of: [restarted], timeout: 1)
        XCTAssertEqual(ready.resumeCalls, 2)
        XCTAssertEqual(ready.ownedResumes, 1, "Only the replacement owns a resume after old cleanup")
    }
}

// Actual WebSurface lifecycle and view retention; only the CEF page boundary is controlled.
@MainActor
private final class WeakRetirementFactory: SurfaceMaking {
    let pages = RetirementPages()
    weak var latest: WebSurface?
    func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
        let surface = WebSurface(size: size, fit: fit, pageFactory: pages)
        latest = surface
        return surface
    }
}

@MainActor
private final class RetirementPages: WebPageMaking {
    weak var latest: RetirementPage?
    func makePage(size: CGSize) throws -> any WebPageSession {
        let page = RetirementPage(size: size)
        latest = page
        return page
    }
}

@MainActor
private final class RetirementPage: WebPageSession {
    let view: NSView
    var onError: ((Error) -> Void)?
    var closeError: Error?
    init(size: CGSize) { view = NSView(frame: CGRect(origin: .zero, size: size)); view.wantsLayer = true }
    func prepare(project: WebProjectReference, scale: CGFloat) async throws {
        view.layer?.backgroundColor = NSColor.red.cgColor
    }
    func setGain(_ linearGain: Double) throws {}
    func sendClick(at point: CGPoint, clickCount: Int) throws { throw WallpaperError("Unexpected click in retirement test") }
    func close() async throws { if let closeError { throw closeError } }
}

@MainActor
private final class HeldCleanupEndpoint: PlaybackEndpoint {
    var releaseFailure: Error?
    var holdCleanup = false
    var resumeError: Error?
    var resumeCalls = 0, playCalls = 0, ownedResumes = 0
    var onResume: (() -> Void)?
    let cleanupStarted = XCTestExpectation(description: "cleanup suspended")
    private var request: UUID?
    private var cleanup: CheckedContinuation<Void, Never>?
    func prepare(item: MediaItem, fit: ContentFit, entry: PlaylistEntry) async throws {}
    func transition(duration: Double, paused: Bool) async -> PlaybackTransitionResult { .displayed }
    func updateAudio(_ settings: [UUID: AudioSettings]) {}
    func discardPreparation() {}
    func setPaused(_ paused: Bool) { if !paused { playCalls += 1 } }
    func prepareToResume(requestID: UUID) async throws {
        request = requestID; resumeCalls += 1; ownedResumes += 1
        onResume?()
        if let resumeError { throw resumeError }
    }
    func cancelResumePreparation(requestID: UUID) async throws {
        guard request == requestID else { return }
        if holdCleanup {
            await withCheckedContinuation { cleanup = $0; cleanupStarted.fulfill() }
        }
        ownedResumes -= 1; request = nil
    }
    func releaseCleanup() { holdCleanup = false; cleanup?.resume(); cleanup = nil }
}
