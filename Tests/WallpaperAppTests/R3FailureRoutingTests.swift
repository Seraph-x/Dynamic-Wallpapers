@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class R3FailureRoutingTests: XCTestCase {
    func testPauseCloseFailureBlocksNextBeforeCreatingPage() async throws {
        try await checkPauseCloseFailure(runtimeErrorFirst: false)
    }

    func testRuntimeErrorThenPauseCloseFailureBlocksNextBeforeCreatingPage() async throws {
        try await checkPauseCloseFailure(runtimeErrorFirst: true)
    }

    private func checkPauseCloseFailure(runtimeErrorFirst: Bool) async throws {
        let fixture = try RoutingFixture()
        defer { fixture.stop() }
        let displayed = expectation(description: "initial webpage displayed")
        fixture.record.onCommit = { _ in displayed.fulfill() }
        fixture.session.start()
        await fulfillment(of: [displayed], timeout: 1)
        fixture.record.onCommit = nil
        let surface = try XCTUnwrap(fixture.factory.surfaces.first)
        let page = try XCTUnwrap(fixture.factory.pages.created.first)
        let retainedView = try XCTUnwrap(surface.subviews.first)
        let closeError = WallpaperError("R3 ordinary pause close failed")
        page.closeError = closeError

        if runtimeErrorFirst { page.onError?(WallpaperError("R3 renderer failed before pause")) }
        else { fixture.session.setPaused(true) }
        await fulfillment(of: [page.closeAttempted], timeout: 1)
        XCTAssertEqual(surface.state, .failed)
        XCTAssertEqual(fixture.window.releaseFailure?.localizedDescription, closeError.localizedDescription,
                       "The host must expose an ordinary pause's failed release before accepting another item")
        XCTAssertTrue(surface.subviews.first === retainedView)

        let unexpectedCreation = expectation(description: "failed old release must prevent new page creation")
        unexpectedCreation.isInverted = true
        unexpectedCreation.assertForOverFulfill = false
        fixture.factory.onSurfaceCreated = { unexpectedCreation.fulfill() }
        fixture.session.next()
        await fulfillment(of: [unexpectedCreation], timeout: 0.15)
        fixture.factory.onSurfaceCreated = nil
        XCTAssertEqual(fixture.factory.surfaces.count, 1, "Next must not allocate a new backend after pause close fails")
        XCTAssertEqual(fixture.record.commits, [fixture.entries[0].id], "Failed release must retain the displayed item")
        XCTAssertTrue(surface.view.superview === fixture.window.contentView, "The original paused frame must remain mounted")
        XCTAssertEqual(fixture.window.activeSurfaceCount, 1, "Only the failed current resource owns a slot")
        fixture.stop()
        do { try await fixture.window.waitForClosing(); XCTFail("Shutdown must preserve the original close failure") }
        catch { XCTAssertEqual(error.localizedDescription, closeError.localizedDescription) }
    }

    func testResumeAfterCancellingInitialLoadRestartsSavedEntry() async throws {
        let fixture = try RoutingFixture(savedCurrent: true)
        defer { fixture.stop() }
        fixture.factory.pages.holdPreparation = true
        fixture.session.start()
        await fulfillment(of: [fixture.factory.pages.firstCreated], timeout: 1)
        let first = try XCTUnwrap(fixture.factory.pages.created.first)
        await fulfillment(of: [first.prepareStarted], timeout: 1)
        fixture.session.setPaused(true)
        try await fixture.window.waitForClosing()
        XCTAssertTrue(fixture.record.commits.isEmpty, "Saved cursor identity is not an actual display commit")
        XCTAssertEqual(fixture.window.activeSurfaceCount, 0)
        XCTAssertTrue(first.closed)

        fixture.factory.pages.holdPreparation = false
        let displayed = expectation(description: "saved entry is prepared again and actually displayed")
        fixture.record.onCommit = { _ in displayed.fulfill() }
        fixture.session.setPaused(false)
        await fulfillment(of: [displayed], timeout: 1)
        fixture.record.onCommit = nil
        XCTAssertEqual(fixture.factory.mediaIDs, [fixture.items[0].id, fixture.items[0].id],
                       "Resume must retry the saved entry instead of treating its cancelled initial load as displayed")
        XCTAssertEqual(fixture.record.commits, [fixture.entries[0].id])
        XCTAssertEqual(fixture.window.activeSurfaceCount, 1)
        XCTAssertEqual(fixture.factory.surfaces.last?.state, .playing)
        XCTAssertTrue(fixture.record.errors.isEmpty)
        fixture.stop()
        try await fixture.window.waitForClosing()
    }
}

@MainActor
private final class RoutingFixture {
    let factory = RoutingSurfaceFactory()
    let record = RoutingRecord()
    let window: DesktopWindow
    let session: PlaybackSession
    let items: [MediaItem]
    let entries: [PlaylistEntry]

    init(savedCurrent: Bool = false) throws {
        _ = NSApplication.shared
        window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main), surfaceFactory: factory)
        items = ["first.html", "second.html"].map { entry in
            MediaItem(url: URL(fileURLWithPath: "/r3-routing/\(entry)"), kind: .web, width: 32, height: 32,
                      backend: .web, webProject: WebProjectReference(root: URL(fileURLWithPath: "/r3-routing"), entry: entry))
        }
        entries = items.map { PlaylistEntry(mediaID: $0.id) }
        let record = self.record
        session = PlaybackSession(playlist: Playlist(name: "R3 failure routing", entries: entries, transition: 0),
            media: items, endpoints: [window], fit: .fit, current: savedCurrent ? entries[0].id : nil,
            autoAdvance: false, onCommit: { id in record.commits.append(id); record.onCommit?(id) },
            onStatus: { record.statuses.append($0) }, onError: { record.errors.append($0) })
        // Match the production coordinator's synchronous pause on endpoint errors.
        window.onPlaybackError = { [weak session] error in
            session?.setPaused(true)
            record.errors.append(error)
        }
    }

    func stop() {
        window.onPlaybackError = nil
        session.stop()
        window.shutdown()
    }
}

@MainActor
private final class RoutingRecord {
    var commits: [UUID] = []
    var errors: [Error] = []
    var statuses: [String] = []
    var onCommit: ((UUID) -> Void)?
}

@MainActor
private final class RoutingSurfaceFactory: SurfaceMaking {
    let pages = RoutingPageFactory()
    var surfaces: [WebSurface] = []
    var mediaIDs: [UUID] = []
    var onSurfaceCreated: (() -> Void)?

    func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
        let surface = WebSurface(size: size, fit: fit, pageFactory: pages)
        surfaces.append(surface)
        mediaIDs.append(item.id)
        onSurfaceCreated?()
        return surface
    }
}

// Only the external CEF boundary is controlled. Session, window, surface, view
// mounting, request identity and release tasks use their production code.
@MainActor
private final class RoutingPageFactory: WebPageMaking {
    var holdPreparation = false
    var created: [RoutingPage] = []
    let firstCreated = XCTestExpectation(description: "first CEF boundary created")

    func makePage(size: CGSize) throws -> any WebPageSession {
        let page = RoutingPage(size: size, holdPreparation: holdPreparation)
        created.append(page)
        if created.count == 1 { firstCreated.fulfill() }
        return page
    }
}

@MainActor
private final class RoutingPage: WebPageSession {
    let view: NSView
    var onError: ((Error) -> Void)?
    var closeError: Error?
    private(set) var closed = false
    let prepareStarted = XCTestExpectation(description: "controlled initial prepare started")
    let closeAttempted = XCTestExpectation(description: "controlled page close attempted")
    private let holdPreparation: Bool
    private var preparation: CheckedContinuation<Void, Error>?

    init(size: CGSize, holdPreparation: Bool) {
        self.holdPreparation = holdPreparation
        view = NSView(frame: CGRect(origin: .zero, size: size))
        view.wantsLayer = true
    }

    func prepare(project: WebProjectReference, scale: CGFloat) async throws {
        if holdPreparation {
            try await withCheckedThrowingContinuation { continuation in
                preparation = continuation
                prepareStarted.fulfill()
            }
        } else { prepareStarted.fulfill() }
        try Task.checkCancellation()
        view.layer?.backgroundColor = NSColor.blue.cgColor
    }

    func setGain(_ linearGain: Double) throws {}
    func sendClick(at point: CGPoint, clickCount: Int) throws { throw WallpaperError("Unexpected click in lifecycle test") }

    func close() async throws {
        closeAttempted.fulfill()
        if let closeError { throw closeError }
        closed = true
        preparation?.resume(throwing: CancellationError())
        preparation = nil
    }
}
