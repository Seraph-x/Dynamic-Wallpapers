import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class DesktopPreviewTests: XCTestCase {
    func testShutdownSnapshotsMirrorCloseBarrierBeforeRetiringPreview() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(screen.wallpaperID)
        let coordinator = DesktopCoordinator(surfaceFactory: ControlledFactory(), screenProvider: { [displayID: screen] })
        defer { coordinator.shutdown() }
        let item = MediaItem(url: URL(fileURLWithPath: "/shutdown-order.png"), kind: .image, width: 32, height: 32)
        let preview = try coordinator.previews.makeSession(id: UUID(), item: item,
            target: DesktopPreviewTarget(displayID: displayID, fit: .fill), onError: { XCTFail($0.localizedDescription) })
        try await preview.prepare()
        try await preview.start()
        let mirror = try coordinator.makeWallpaperMirror(on: screen)
        let originalRelease = coordinator.previews.releaseSources
        var snapshots = 0
        coordinator.previews.releaseSources = { ids in
            let snapshot = mirror.sourceReleaseBarrier()
            let shutdown = mirror.beginClose()
            XCTAssertEqual(snapshot, shutdown, "Preview teardown must snapshot the actual mirror shutdown, not an earlier source change")
            snapshots += 1
            return originalRelease?(ids)
        }
        coordinator.shutdown()
        try await coordinator.waitForShutdown()
        XCTAssertEqual(snapshots, 1)
        XCTAssertTrue(mirror.isClosed)
    }

    func testPreviewWindowStaysAliveUntilItsMirrorReleaseBarrierCompletes() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let preview = try fixture.makePreview()
        try await preview.prepare()
        try await preview.start()
        let window = try XCTUnwrap(preview.window(on: "A"))
        let entered = expectation(description: "mirror source release pending")
        var release: CheckedContinuation<Void, Never>?
        fixture.coordinator.previews.releaseSources = { ids in
            XCTAssertEqual(ids, ["A"])
            return Task { @MainActor in
                await withCheckedContinuation { release = $0; entered.fulfill() }
                XCTAssertTrue(window.isVisible, "A screenshot in flight must retain a live source window")
            }
        }
        var finished = false
        let closing = Task { try await preview.beginClose().value; finished = true }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertFalse(finished)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.contentView?.isHidden == true, "A retained capture source must no longer cover the real desktop")
        XCTAssertFalse(fixture.factory.records.last?.surface.playing ?? true)
        XCTAssertFalse(fixture.coordinator.wallpaperWindow(on: "A") === window)
        release?.resume(); release = nil
        try await closing.value
        XCTAssertFalse(window.isVisible)
    }

    func testSourceChangeIsPublishedBeforeThePreviewWindowIsDestroyed() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let preview = try fixture.makePreview()
        try await preview.prepare()
        try await preview.start()
        let window = try XCTUnwrap(preview.window(on: "A"))
        let originalChange = fixture.coordinator.previews.onChange
        var notifiedBeforeDestruction = false
        fixture.coordinator.previews.onChange = {
            if !preview.isActive { notifiedBeforeDestruction = window.isVisible }
            originalChange?()
        }
        try await preview.beginClose().value
        XCTAssertTrue(notifiedBeforeDestruction, "Mirror consumers must retire their old capture before the source closes")
    }

    func testPreviewWaitsForInFlightTransitionBeforeSuspendingItsCommittedBaseline() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let outgoing = fixture.factory.records[0].surface
        outgoing.holdClose = true
        defer { outgoing.finishClose() }
        fixture.library.displays[0].source = .media(fixture.candidate.id, audio: AudioSettings())
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [outgoing.closeStarted], timeout: 2)
        let baseline = fixture.factory.records[1].surface
        let preview = try fixture.makePreview()
        try await preview.prepare()
        var started = false
        let starting = Task { try await preview.start(); started = true }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(started, "A preview must not snapshot ownership in the middle of a committed transition")
        XCTAssertTrue(baseline.playing)
        outgoing.finishClose()
        try await starting.value
        XCTAssertFalse(baseline.playing)
        try await preview.beginClose().value
        try await fixture.wait { baseline.playing }
        XCTAssertEqual(fixture.factory.records.count, 3)
        XCTAssertEqual(baseline.state, .playing)
    }

    func testPreviewPausesAndRestoresTheWholeSynchronizedGroup() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        let binding = fixture.library.displays[0]
        fixture.library.displays.append(DisplayBinding(id: "B", source: binding.source, groupID: binding.groupID))
        try await fixture.displayOriginal()
        let original = fixture.factory.records.map(\.surface)
        let preview = try fixture.makePreview(on: "A")
        try await preview.prepare()
        try await preview.start()
        XCTAssertTrue(original.allSatisfy { !$0.playing })
        try await preview.beginClose().value
        try await fixture.wait { original.allSatisfy(\.playing) }
        XCTAssertEqual(fixture.factory.records.count, 3)
    }

    func testPreviewTemporarilyOverridesDesktopAndResumesTheOriginalSurface() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let original = try XCTUnwrap(fixture.factory.records.first?.surface)
        let originalWindow = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "A"))
        let preview = try fixture.makePreview()
        try await preview.prepare()
        XCTAssertTrue(fixture.coordinator.wallpaperWindow(on: "A") === originalWindow)
        XCTAssertTrue(original.playing, "Preparation must not hide or interrupt the old wallpaper")
        try await preview.start()
        let temporary = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "A"))
        XCTAssertFalse(temporary === originalWindow)
        XCTAssertGreaterThan(temporary.level.rawValue, originalWindow.level.rawValue)
        XCTAssertLessThan(temporary.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)))
        XCTAssertFalse(original.playing)
        let candidate = try XCTUnwrap(fixture.factory.records.last?.surface)
        XCTAssertTrue(candidate.playing)
        XCTAssertTrue(candidate.globallyMuted)

        try await preview.beginClose().value
        try await fixture.wait { original.playing }
        XCTAssertTrue(fixture.coordinator.wallpaperWindow(on: "A") === originalWindow)
        XCTAssertEqual(fixture.factory.records.count, 2)
        XCTAssertEqual(candidate.state, .closed)
        XCTAssertEqual(fixture.commits.count, 1, "Preview never commits into the persisted playlist cursor")
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testOnlySelectedIndependentDisplayIsSuspendedAndOverridden() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        fixture.library.displays.append(DisplayBinding(id: "B", source: .media(fixture.original.id, audio: AudioSettings())))
        try await fixture.displayOriginal()
        let second = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "B"))
        let preview = try fixture.makePreview(on: "A")
        try await preview.prepare()
        try await preview.start()
        XCTAssertTrue(fixture.coordinator.wallpaperWindow(on: "B") === second)
        XCTAssertEqual(fixture.factory.records.prefix(2).filter { $0.surface.playing }.count, 1)
        XCTAssertEqual(preview.displayIDs, ["A"])
        try await preview.beginClose().value
        try await fixture.wait { fixture.factory.records.prefix(2).allSatisfy { $0.surface.playing } }
    }

    func testAllDisplayPreviewIsMutedAndOriginalPauseIntentSurvives() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        fixture.coordinator.setPaused(true)
        let original = fixture.factory.records[0].surface
        let preview = try fixture.makePreview(on: nil)
        try await preview.prepare()
        try await preview.start()
        XCTAssertEqual(preview.displayIDs, ["A", "B"])
        XCTAssertTrue(fixture.factory.records.suffix(2).allSatisfy { $0.surface.globallyMuted && $0.surface.playing })
        fixture.coordinator.reconcile(fixture.library)
        XCTAssertTrue(fixture.factory.records.suffix(2).allSatisfy { $0.surface.globallyMuted })
        try await preview.beginClose().value
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(original.playing)
    }

    func testInvalidTargetDoesNotFallBackToAnotherScreen() throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        XCTAssertThrowsError(try fixture.makePreview(on: "missing")) {
            XCTAssertTrue($0.localizedDescription.contains("断开"))
        }
        XCTAssertTrue(fixture.factory.records.isEmpty)
    }

    func testPreparationFailureLeavesOriginalVisibleAndReleasesCandidate() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let original = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "A"))
        fixture.factory.configure = { $0.prepareError = WallpaperError("desktop prepare failed") }
        let preview = try fixture.makePreview()
        do { try await preview.prepare(); XCTFail("Preparation must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("desktop prepare failed")) }
        try await preview.beginClose().value
        XCTAssertTrue(fixture.coordinator.wallpaperWindow(on: "A") === original)
        XCTAssertTrue(fixture.factory.records[0].surface.playing)
        XCTAssertEqual(fixture.factory.records[1].surface.state, .closed)
    }

    func testDisconnectEndsPreviewAndRestoresOriginal() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let preview = try fixture.makePreview()
        try await preview.prepare()
        try await preview.start()
        fixture.coordinator.previews.refreshScreens(["B": fixture.screen])
        try await preview.beginClose().value
        try await fixture.wait { fixture.factory.records[0].surface.playing }
        XCTAssertTrue(fixture.errors.contains { $0.contains("显示器") })
    }

    func testCloseFailureRemainsOwnedAndPreventsReplacement() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let preview = try fixture.makePreview()
        try await preview.prepare()
        try await preview.start()
        fixture.factory.records[1].surface.closeError = WallpaperError("desktop close failed")
        do { try await preview.beginClose().value; XCTFail("Close must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("desktop close failed")) }
        try await fixture.wait { fixture.factory.records[0].surface.playing }
        XCTAssertThrowsError(try fixture.makePreview())
        XCTAssertEqual(preview.activeSurfaceCount, 1)
        XCTAssertEqual(fixture.factory.records.count, 2)
        fixture.coordinator.shutdown()
        do { try await fixture.coordinator.waitForShutdown(); XCTFail("Shutdown must expose close failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("desktop close failed")) }
    }
}
