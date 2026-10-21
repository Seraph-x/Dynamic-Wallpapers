@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class DesktopInteractionRoutingTests: XCTestCase {
    private let item = MediaItem(url: URL(fileURLWithPath: "/finder-click-test/index.html"), kind: .web,
        width: 320, height: 180, backend: .web,
        webProject: WebProjectReference(root: URL(fileURLWithPath: "/finder-click-test"), entry: "index.html"))

    func testWebPreviewOnAnUnboundDisplayHasItsOwnClickTarget() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let id = try XCTUnwrap(screen.wallpaperID)
        let factory = RecordingFactory()
        let coordinator = DesktopCoordinator(surfaceFactory: factory, screenProvider: { [id: screen] })
        defer { coordinator.shutdown() }
        var library = Library.empty
        library.settings.webInteractionEnabled = true
        coordinator.setWebInteractionEnabled(true)
        coordinator.reconcile(library)
        coordinator.setPaused(true)
        let preview = try coordinator.previews.makeSession(id: UUID(), item: item,
            target: DesktopPreviewTarget(displayID: id, fit: .fill), onError: { XCTFail($0.localizedDescription) })
        try await preview.prepare()
        try await preview.start()
        let number = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let bounds = CGDisplayBounds(number.uint32Value)
        let target = try XCTUnwrap(coordinator.desktopClickTarget(at: CGPoint(x: bounds.midX, y: bounds.midY)))
        XCTAssertEqual(target.screenID, id)
        let window = try XCTUnwrap(coordinator.wallpaperWindow(on: id))
        XCTAssertTrue(try window.sendDesktopClick(atScreenPoint: CGPoint(x: screen.frame.midX, y: screen.frame.midY),
                                                 clickCount: 1, target: target))
        XCTAssertEqual(factory.pages[0].clicks.count, 1)
        coordinator.setWebInteractionEnabled(false)
        coordinator.reconcile(library)
        XCTAssertNil(coordinator.desktopClickTarget(at: CGPoint(x: bounds.midX, y: bounds.midY)),
                     "A stale enabled library must not undo an explicit disable")
        try await preview.beginClose().value
        XCTAssertNil(coordinator.desktopClickTarget(at: CGPoint(x: bounds.midX, y: bounds.midY)))
        coordinator.shutdown()
        try await coordinator.waitForShutdown()
    }

    func testOnlyDisplayedWebpageReceivesLocalTopLeftClickAndDoubleClickCount() async throws {
        let (window, factory) = try fixture()
        defer { window.shutdown() }
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        XCTAssertNil(window.desktopClickTarget(screenID: "display"))
        _ = await window.transition(duration: 0, paused: false)
        let target = try XCTUnwrap(window.desktopClickTarget(screenID: "display"))
        XCTAssertTrue(try window.sendDesktopClick(atScreenPoint: CGPoint(x: 130, y: 250), clickCount: 2, target: target))
        XCTAssertEqual(factory.pages[0].clicks, [RecordedClick(point: CGPoint(x: 80, y: 30), count: 2)])
        window.shutdown()
        try await window.waitForClosing()
        XCTAssertNil(window.desktopClickTarget(screenID: "display"))
        XCTAssertThrowsError(try window.sendDesktopClick(atScreenPoint: CGPoint(x: 130, y: 250), clickCount: 1, target: target))
    }

    func testGeometryChangeInvalidatesOldClickEvenWhenWebpageIdentityIsUnchanged() async throws {
        let (window, factory) = try fixture()
        defer { window.shutdown() }
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        _ = await window.transition(duration: 0, paused: false)
        let old = try XCTUnwrap(window.desktopClickTarget(screenID: "display"))
        window.updateGeometry(frame: CGRect(x: 60, y: 100, width: 320, height: 180), scale: 1)
        let current = try XCTUnwrap(window.desktopClickTarget(screenID: "display"))
        XCTAssertEqual(current.pageID, old.pageID)
        XCTAssertNotEqual(current.interactionGeneration, old.interactionGeneration)
        XCTAssertThrowsError(try window.sendDesktopClick(atScreenPoint: CGPoint(x: 130, y: 250), clickCount: 1, target: old))
        XCTAssertTrue(factory.pages[0].clicks.isEmpty)
        window.shutdown()
        try await window.waitForClosing()
    }

    func testPauseAndReloadCannotAcceptAnEarlierPageClick() async throws {
        let (window, factory) = try fixture()
        defer { window.shutdown() }
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        _ = await window.transition(duration: 0, paused: false)
        let old = try XCTUnwrap(window.desktopClickTarget(screenID: "display"))
        window.setPaused(true)
        XCTAssertNil(window.desktopClickTarget(screenID: "display"))
        XCTAssertThrowsError(try window.sendDesktopClick(atScreenPoint: CGPoint(x: 130, y: 250), clickCount: 1, target: old))
        try await window.prepareToResume(requestID: UUID())
        XCTAssertNil(window.desktopClickTarget(screenID: "display"))
        window.setPaused(false)
        let current = try XCTUnwrap(window.desktopClickTarget(screenID: "display"))
        XCTAssertNotEqual(current.pageID, old.pageID)
        XCTAssertThrowsError(try window.sendDesktopClick(atScreenPoint: CGPoint(x: 130, y: 250), clickCount: 1, target: old))
        XCTAssertTrue(factory.pages.allSatisfy { $0.clicks.isEmpty })
        window.shutdown()
        try await window.waitForClosing()
    }

    func testTransitionAndOutgoingReleaseNeverExposeIncomingClickTarget() async throws {
        let (window, factory) = try fixture()
        defer { factory.pages.forEach { $0.finishClose() }; window.shutdown() }
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        _ = await window.transition(duration: 0, paused: false)
        let old = try XCTUnwrap(window.desktopClickTarget(screenID: "display"))
        let first = factory.pages[0]
        first.holdClose = true
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        let transition = Task { await window.transition(duration: 0.01, paused: false) }
        await fulfillment(of: [first.closeStarted], timeout: 1)
        XCTAssertNil(window.desktopClickTarget(screenID: "display"))
        XCTAssertThrowsError(try window.sendDesktopClick(atScreenPoint: CGPoint(x: 130, y: 250), clickCount: 1, target: old))
        first.finishClose()
        let result = await transition.value
        XCTAssertTrue(result.didDisplay)
        let current = try XCTUnwrap(window.desktopClickTarget(screenID: "display"))
        XCTAssertNotEqual(current.pageID, old.pageID)
        XCTAssertTrue(factory.pages.allSatisfy { $0.clicks.isEmpty })
        window.shutdown()
        try await window.waitForClosing()
    }

    private func fixture() throws -> (DesktopWindow, RecordingFactory) {
        _ = NSApplication.shared
        let factory = RecordingFactory()
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main), surfaceFactory: factory)
        window.updateGeometry(frame: CGRect(x: 50, y: 100, width: 320, height: 180), scale: 1)
        return (window, factory)
    }

    private struct RecordedClick: Equatable {
        let point: CGPoint
        let count: Int
    }

    private final class RecordingFactory: SurfaceMaking, WebPageMaking {
        var pages: [RecordingPage] = []
        func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
            WebSurface(size: size, fit: fit, pageFactory: self)
        }
        func makePage(size: CGSize) throws -> any WebPageSession {
            let page = RecordingPage(size: size)
            pages.append(page)
            return page
        }
    }

    private final class RecordingPage: WebPageSession {
        let view: NSView
        var onError: ((Error) -> Void)?
        var clicks: [RecordedClick] = []
        var holdClose = false
        let closeStarted = XCTestExpectation(description: "old page closing")
        private var closing: CheckedContinuation<Void, Never>?
        init(size: CGSize) { view = NSView(frame: CGRect(origin: .zero, size: size)) }
        func prepare(project: WebProjectReference, scale: CGFloat) async throws {}
        func setGain(_ linearGain: Double) throws {}
        func sendClick(at point: CGPoint, clickCount: Int) throws {
            clicks.append(RecordedClick(point: point, count: clickCount))
        }
        func close() async throws {
            closeStarted.fulfill()
            if holdClose { await withCheckedContinuation { closing = $0 } }
        }
        func finishClose() { closing?.resume(); closing = nil }
    }
}
