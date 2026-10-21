import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SystemWallpaperDesktopTests: XCTestCase {
    func testDirectAndPlaylistCommitsPublishFormalTargetsWithoutPreviewOrAudioUpdates() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        let source = fixture.coordinator.systemWallpaperSource
        var changes = 0
        source.onChange = { _ in changes += 1 }
        try await fixture.displayOriginal()
        let direct = try XCTUnwrap(source.targets.first)
        XCTAssertEqual(direct.content.item.id, fixture.original.id)
        XCTAssertEqual(direct.displayID, "A")
        XCTAssertTrue(source.isCurrent(direct))
        let count = changes
        fixture.coordinator.setPaused(true)
        fixture.library.settings.isMuted = true
        fixture.coordinator.reconcile(fixture.library)
        let preview = try fixture.makePreview()
        try await preview.prepare(); try await preview.start()
        XCTAssertEqual(source.targets, [direct])
        try await preview.beginClose().value
        XCTAssertEqual(changes, count)
        fixture.library.playlists[0].entries = [PlaylistEntry(mediaID: fixture.original.id)]
        fixture.library.displays[0].source = .playlist(fixture.library.playlists[0].id)
        fixture.coordinator.reconcile(fixture.library)
        try await fixture.wait { fixture.commits.count == 2 }
        let playlist = try XCTUnwrap(source.targets.first)
        XCTAssertEqual(playlist.content.item.id, direct.content.item.id)
        XCTAssertNotEqual(playlist.revision, direct.revision)
        XCTAssertGreaterThan(changes, count)
    }

    func testSystemCaptureChoosesFormalWindowEvenWhilePreviewIsVisible() async throws {
        var captured: NSWindow?
        let source = DesktopWallpaperSource(capture: { window in
            captured = window
            return try SystemWallpaperFiles.image()
        })
        let fixture = try DesktopPreviewFixture(systemWallpaperSource: source)
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let formal = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "A"))
        let target = try XCTUnwrap(source.targets.first)
        let preview = try fixture.makePreview()
        try await preview.prepare(); try await preview.start()
        XCTAssertFalse(fixture.coordinator.wallpaperWindow(on: "A") === formal)
        _ = try await source.capture(target)
        XCTAssertTrue(captured === formal)
        try await preview.beginClose().value
    }

    func testSwitchOrGeometryChangeInvalidatesAnInFlightSnapshot() async throws {
        for change in ["switch", "resize"] {
            let started = expectation(description: change)
            var pending: CheckedContinuation<CGImage, Error>?
            let source = DesktopWallpaperSource(capture: { _ in
                try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
            })
            let fixture = try DesktopPreviewFixture(systemWallpaperSource: source)
            defer { fixture.close() }
            try await fixture.displayOriginal()
            let target = try XCTUnwrap(source.targets.first)
            let capture = Task { try await source.capture(target) }
            await fulfillment(of: [started], timeout: 2)
            if change == "switch" {
                fixture.library.media.append(fixture.candidate)
                fixture.library.displays[0].source = .media(fixture.candidate.id, audio: AudioSettings())
                fixture.coordinator.reconcile(fixture.library)
                try await fixture.wait { fixture.commits.count == 2 }
            } else {
                let window = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "A"))
                window.updateGeometry(frame: CGRect(x: 0, y: 0, width: 100, height: 80), scale: 1)
            }
            XCTAssertFalse(source.isCurrent(target))
            try XCTUnwrap(pending).resume(returning: SystemWallpaperFiles.image())
            do { _ = try await capture.value; XCTFail("Stale pixels accepted") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testUnbindRetainsWindowUntilCaptureFinishesAndBlocksPrematureRebind() async throws {
        let started = expectation(description: "capture owns window")
        var pending: CheckedContinuation<CGImage, Error>?
        let source = DesktopWallpaperSource(capture: { _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        })
        let fixture = try DesktopPreviewFixture(systemWallpaperSource: source)
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let target = try XCTUnwrap(source.targets.first)
        let window = try XCTUnwrap(fixture.coordinator.wallpaperWindow(on: "A"))
        let surface = try XCTUnwrap(fixture.factory.records.first?.surface)
        let capture = Task { try await source.capture(target) }
        await fulfillment(of: [started], timeout: 2)
        let bindings = fixture.library.displays
        fixture.library.displays = []
        fixture.coordinator.reconcile(fixture.library)
        XCTAssertTrue(source.targets.isEmpty)
        XCTAssertTrue(window.isVisible, "Capture's source window must remain alive")
        XCTAssertEqual(window.contentView?.isHidden, true)
        XCTAssertFalse(surface.playing)
        XCTAssertNotEqual(surface.state, .closed)
        fixture.library.displays = bindings
        fixture.coordinator.reconcile(fixture.library)
        XCTAssertNil(fixture.coordinator.wallpaperWindow(on: "A"))
        try XCTUnwrap(pending).resume(returning: SystemWallpaperFiles.image())
        do { _ = try await capture.value; XCTFail("Retired source accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await fixture.wait { fixture.commits.count == 2 }
        XCTAssertEqual(surface.state, .closed)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(fixture.coordinator.wallpaperWindow(on: "A") === window)
    }

    func testShutdownWaitsForCapturedWindowBeforeClosingItsSurface() async throws {
        let started = expectation(description: "capture owns shutdown window")
        var pending: CheckedContinuation<CGImage, Error>?
        let source = DesktopWallpaperSource(capture: { _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        })
        let fixture = try DesktopPreviewFixture(systemWallpaperSource: source)
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let target = try XCTUnwrap(source.targets.first)
        let surface = try XCTUnwrap(fixture.factory.records.first?.surface)
        let capture = Task { try await source.capture(target) }
        await fulfillment(of: [started], timeout: 2)
        fixture.coordinator.shutdown()
        var closed = false
        let closing = Task { try await fixture.coordinator.waitForShutdown(); closed = true }
        await Task.yield()
        XCTAssertFalse(closed)
        XCTAssertNotEqual(surface.state, .closed)
        try XCTUnwrap(pending).resume(returning: SystemWallpaperFiles.image())
        do { _ = try await capture.value; XCTFail("Shutdown source accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await closing.value
        XCTAssertTrue(closed)
        XCTAssertEqual(surface.state, .closed)
    }
}
