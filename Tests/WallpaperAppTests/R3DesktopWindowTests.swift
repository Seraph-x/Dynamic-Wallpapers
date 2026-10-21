import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class R3DesktopWindowTests: XCTestCase {
    func testPausedTransitionPausesPreparedBackendAndKeepsItsView() async throws {
        _ = NSApplication.shared
        let factory = ControlledFactory()
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main), surfaceFactory: factory)
        let item = MediaItem(url: URL(fileURLWithPath: "/paused.png"), kind: .image, width: 32, height: 32)
        try await window.prepare(item: item, fit: .fit, entry: PlaylistEntry(mediaID: item.id))
        let result = await window.transition(duration: 0, paused: true)
        XCTAssertTrue(result.didDisplay)
        XCTAssertEqual(factory.surfaces[0].state, .paused)
        XCTAssertTrue(factory.surfaces[0].view.superview === window.contentView)
        window.shutdown()
        try await window.waitForClosing()
    }

    func testSessionPauseCancelsPendingWindowPreparationAndRetainsCurrent() async throws {
        _ = NSApplication.shared
        let factory = ControlledFactory()
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main), surfaceFactory: factory)
        let item = MediaItem(url: URL(fileURLWithPath: "/pending.png"), kind: .image, width: 32, height: 32)
        let entries = [PlaylistEntry(mediaID: item.id), PlaylistEntry(mediaID: item.id)]
        let displayed = expectation(description: "initial display")
        var commits = 0
        let session = PlaybackSession(playlist: Playlist(name: "R3", entries: entries, transition: 0),
            media: [item], endpoints: [window], fit: .fit, autoAdvance: false,
            onCommit: { _ in commits += 1; if commits == 1 { displayed.fulfill() } },
            onStatus: { _ in }, onError: { XCTFail($0.localizedDescription) })
        session.start()
        await fulfillment(of: [displayed], timeout: 1)
        factory.holdPrepare = true
        session.next()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while factory.surfaces.count < 2 && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let pending = try XCTUnwrap(factory.surfaces.dropFirst().first)
        await fulfillment(of: [pending.prepareStarted], timeout: 1)
        session.setPaused(true)
        await fulfillment(of: [pending.closeStarted], timeout: 1)
        pending.finishPrepare()
        try await window.waitForClosing()
        XCTAssertEqual(window.activeSurfaceCount, 1)
        XCTAssertTrue(factory.surfaces[0].view.superview === window.contentView)
        XCTAssertEqual(factory.surfaces[0].state, .paused)
        XCTAssertNil(pending.view.superview)
        XCTAssertEqual(commits, 1)
        session.stop(); window.shutdown()
        try await window.waitForClosing()
    }
}
