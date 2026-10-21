import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SurfaceTransitionFailureTests: XCTestCase {
    func testFailedCloseWaitsForEveryScreenThenPausesWithoutLosingDisplayedIdentity() async throws {
        _ = NSApplication.shared
        let factories = [ControlledFactory(), ControlledFactory()]
        let screen = try XCTUnwrap(NSScreen.main)
        let windows = factories.map { DesktopWindow(screen: screen, surfaceFactory: $0) }
        defer { windows.forEach { $0.shutdown() } }
        let item = MediaItem(url: URL(fileURLWithPath: "/transition.png"), kind: .image, width: 32, height: 32)
        let entries = (0..<3).map { index in PlaylistEntry(mediaID: item.id, timing: EntryTiming(seconds: index == 0 ? 3600 : 0.01)) }
        let initial = expectation(description: "initial frame committed")
        var commits: [UUID] = []
        var status = ""
        var errors: [String] = []
        let session = PlaybackSession(playlist: Playlist(name: "test", entries: entries, transition: 0),
            media: [item], endpoints: windows, fit: .fit, autoAdvance: true,
            onCommit: { id in commits.append(id); if id == entries[0].id { initial.fulfill() } },
            onStatus: { status = $0 }, onError: { errors.append($0.localizedDescription) })
        defer { session.stop() }
        session.start()
        await fulfillment(of: [initial], timeout: 1)
        let failed = factories[0].surfaces[0], slow = factories[1].surfaces[0]
        failed.closeError = WallpaperError("old decoder close failed")
        slow.holdClose = true
        session.next()
        await fulfillment(of: [failed.closeStarted, slow.closeStarted], timeout: 1)
        session.next() // This queued request must be cleared by the failed release.
        XCTAssertTrue(session.isTransitioning)
        XCTAssertEqual(session.currentEntryID, entries[0].id)
        XCTAssertTrue(errors.isEmpty, "Wait for the other screen's visible transaction before reporting")
        slow.finishClose()
        try await waitUntil { !session.isTransitioning }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(commits, [entries[0].id, entries[1].id], "Both screens did display the new entry")
        XCTAssertEqual(session.currentEntryID, entries[1].id)
        XCTAssertEqual(errors, ["old decoder close failed"])
        XCTAssertEqual(status, "播放器资源释放失败，已暂停")
        XCTAssertEqual(windows[0].activeSurfaceCount, 2)
        XCTAssertEqual(windows[1].activeSurfaceCount, 1)
        XCTAssertEqual(factories.map { $0.surfaces.count }, [2, 2], "Queued next must not allocate another surface")
        XCTAssertTrue(factories.allSatisfy { !$0.surfaces[1].playing })
        session.setPaused(false)
        session.next()
        // Cross the prepared entry's automatic deadline; the failed release must still block allocation.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(factories.map { $0.surfaces.count }, [2, 2])
        XCTAssertTrue(factories.allSatisfy { !$0.surfaces[1].playing }, "Failed release remains unresolved on resume")
        XCTAssertEqual(status, "播放器资源释放失败，已暂停")
        XCTAssertEqual(errors, ["old decoder close failed"], "The raw failure remains on the error channel")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Transition completion timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
