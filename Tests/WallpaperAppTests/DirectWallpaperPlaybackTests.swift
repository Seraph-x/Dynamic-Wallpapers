@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class DirectWallpaperPlaybackTests: XCTestCase {
    func testDirectWallpaperIgnoresNextAndResumesWithoutRecreatingSurface() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let displayed = expectation(description: "direct wallpaper displayed")
        fixture.coordinator.onCommit = { _, _ in displayed.fulfill() }
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [displayed], timeout: 1)
        let surface = try XCTUnwrap(fixture.factory.surfaces.first?.surface)
        XCTAssertTrue(surface.playing)
        fixture.coordinator.next()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.factory.surfaces.count, 1)
        fixture.coordinator.setPaused(true)
        XCTAssertFalse(surface.playing)
        let resumed = expectation(description: "direct wallpaper resumed")
        fixture.coordinator.onStatus = { _, status in if status == "正在播放" { resumed.fulfill() } }
        fixture.coordinator.setPaused(false)
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertTrue(surface.playing)
        XCTAssertEqual(fixture.factory.surfaces.count, 1)
    }

    func testSynchronizedAudioEditKeepsBothPendingSurfaces() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.factory.holdPrepare = true
        var library = fixture.library
        let source = library.displays[0]
        library.displays.append(DisplayBinding(id: "B", source: source.source, groupID: source.groupID))
        let displayed = expectation(description: "both screens committed together")
        fixture.coordinator.onCommit = { _, _ in displayed.fulfill() }
        fixture.coordinator.reconcile(library)
        try await wait { fixture.factory.surfaces.count == 2 }
        let pending = fixture.factory.surfaces.map(\.surface)
        await fulfillment(of: pending.map(\.prepareStarted), timeout: 1)
        let audio = AudioSettings(isMuted: true, volume: 0.42)
        for index in library.displays.indices { library.displays[index].source = .media(fixture.items[0].id, audio: audio) }
        library.settings.isMuted = false
        fixture.coordinator.reconcile(library)
        XCTAssertTrue(pending.allSatisfy { $0.audio == audio && !$0.globallyMuted })
        pending.forEach { $0.finishPrepare() }
        await fulfillment(of: [displayed], timeout: 1)
        XCTAssertEqual(fixture.factory.surfaces.count, 2)
        XCTAssertTrue(pending.allSatisfy { $0.playing && $0.audio == audio })
    }

    func testDirectAudioEditDuringTransitionDoesNotRestartPlayback() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var library = fixture.library
        let displayed = expectation(description: "original transition commits once")
        fixture.coordinator.onCommit = { _, _ in displayed.fulfill() }
        fixture.coordinator.reconcile(library)
        try await wait { fixture.factory.surfaces.first?.surface.playing == true }
        let surface = try XCTUnwrap(fixture.factory.surfaces.first?.surface)
        let audio = AudioSettings(volume: 0.6)
        library.displays[0].source = .media(fixture.items[0].id, audio: audio)
        fixture.coordinator.reconcile(library)
        XCTAssertEqual(surface.audio, audio)
        await fulfillment(of: [displayed], timeout: 1)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.factory.surfaces.count, 1)
        XCTAssertTrue(surface.playing)
    }

    func testDirectAndPlaylistSourcesSwitchInBothDirectionsAndReleaseOldSurface() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var library = fixture.library
        let first = expectation(description: "direct frame")
        fixture.coordinator.onCommit = { _, _ in first.fulfill() }
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [first], timeout: 1)
        let direct = try XCTUnwrap(fixture.factory.surfaces.first?.surface)
        let next = expectation(description: "playlist frame")
        fixture.coordinator.onCommit = { _, entry in
            XCTAssertEqual(entry, library.playlists[0].entries[0].id)
            next.fulfill()
        }
        library.displays[0].source = .playlist(library.playlists[0].id)
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [next], timeout: 1)
        XCTAssertEqual(direct.state, .closed)
        let playlistSurface = try XCTUnwrap(fixture.factory.surfaces.last?.surface)
        let restored = expectation(description: "direct frame restored")
        fixture.coordinator.onCommit = { _, _ in restored.fulfill() }
        library.displays[0].source = .media(fixture.items[0].id, audio: AudioSettings())
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(playlistSurface.state, .closed)
        XCTAssertEqual(fixture.factory.surfaces.count, 3)
        XCTAssertTrue(fixture.factory.surfaces.last?.surface.playing == true)
    }

    func testGlobalNextOnlyAdvancesThePlaylistGroup() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var library = fixture.library
        library.playlists[0].entries.append(PlaylistEntry(mediaID: fixture.items[0].id))
        let playlistBinding = DisplayBinding(id: "B", playlistID: library.playlists[0].id)
        library.displays.append(playlistBinding)
        let initial = expectation(description: "both sources displayed")
        initial.expectedFulfillmentCount = 2
        fixture.coordinator.onCommit = { _, _ in initial.fulfill() }
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [initial], timeout: 1)
        let direct = try XCTUnwrap(fixture.factory.surfaces.first { $0.mediaID == fixture.items[0].id }?.surface)
        fixture.coordinator.next(groupID: UUID())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.factory.surfaces.count, 2, "A stale group cannot advance every display")
        let advanced = expectation(description: "only playlist advances")
        fixture.coordinator.onCommit = { group, entry in
            XCTAssertEqual(group, playlistBinding.groupID)
            XCTAssertEqual(entry, library.playlists[0].entries[1].id)
            advanced.fulfill()
        }
        fixture.coordinator.next()
        await fulfillment(of: [advanced], timeout: 1)
        XCTAssertEqual(fixture.factory.surfaces.count, 3)
        XCTAssertTrue(direct.playing)
        XCTAssertNotEqual(direct.state, .closed)
    }

    func testFailedReplacementKeepsTheDirectWallpaperVisible() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var library = fixture.library
        let first = expectation(description: "direct frame")
        fixture.coordinator.onCommit = { _, _ in first.fulfill() }
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [first], timeout: 1)
        let original = try XCTUnwrap(fixture.factory.surfaces.first?.surface)
        fixture.factory.prepareError = WallpaperError("replacement failed")
        let failed = expectation(description: "preparation failure is reported")
        fixture.coordinator.onError = { error in
            XCTAssertEqual(error.localizedDescription, "replacement failed")
            failed.fulfill()
        }
        fixture.coordinator.onCommit = { _, _ in XCTFail("failed replacement cannot commit") }
        library.displays[0].source = .playlist(library.playlists[0].id)
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(original.playing)
        XCTAssertEqual(original.view.alphaValue, 1)
        XCTAssertEqual(fixture.factory.surfaces.last?.surface.state, .closed)
    }

    func testUnbindingDirectWallpaperSilencesAndWaitsForItsClose() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let displayed = expectation(description: "direct frame")
        fixture.coordinator.onCommit = { _, _ in displayed.fulfill() }
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [displayed], timeout: 1)
        let surface = try XCTUnwrap(fixture.factory.surfaces.first?.surface)
        surface.holdClose = true
        var library = fixture.library
        library.displays = []
        fixture.coordinator.reconcile(library)
        XCTAssertTrue(surface.suppressed)
        await fulfillment(of: [surface.closeStarted], timeout: 1)
        XCTAssertEqual(surface.state, .closing)
        surface.finishClose()
        fixture.coordinator.shutdown()
        try await fixture.coordinator.waitForShutdown()
        XCTAssertEqual(surface.state, .closed)
    }

    func testFailedDirectRetirementIsReportedAndPreventsRebindingOverTheResource() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let displayed = expectation(description: "direct frame")
        fixture.coordinator.onCommit = { _, _ in displayed.fulfill() }
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [displayed], timeout: 1)
        let surface = try XCTUnwrap(fixture.factory.surfaces.first?.surface)
        surface.closeError = WallpaperError("direct resource release failed")
        let failed = expectation(description: "release failure remains visible")
        failed.assertForOverFulfill = false
        fixture.coordinator.onError = { error in
            XCTAssertTrue(error.localizedDescription.contains("direct resource release failed"))
            failed.fulfill()
        }
        var unbound = fixture.library
        unbound.displays = []
        fixture.coordinator.reconcile(unbound)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(surface.state, .failed)
        XCTAssertTrue(surface.suppressed)
        fixture.coordinator.reconcile(fixture.library)
        XCTAssertEqual(fixture.factory.surfaces.count, 1)
        fixture.coordinator.shutdown()
        do { try await fixture.coordinator.waitForShutdown(); XCTFail("Shutdown must expose the retained close failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("direct resource release failed")) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Direct playback did not reach the expected state") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor private struct Fixture {
        let factory = RecordingFactory()
        let coordinator: DesktopCoordinator
        let items: [MediaItem]
        let library: Library

        init() throws {
            _ = NSApplication.shared
            let screen = try XCTUnwrap(NSScreen.main)
            coordinator = DesktopCoordinator(surfaceFactory: factory, screenProvider: { ["A": screen, "B": screen] })
            items = ["direct", "playlist"].map {
                MediaItem(url: URL(fileURLWithPath: "/\($0).png"), kind: .image, width: 32, height: 32)
            }
            var library = Library.empty
            library.media = items
            library.playlists[0].entries = [PlaylistEntry(mediaID: items[1].id)]
            library.playlists[0].transition = 0
            library.displays = [DisplayBinding(id: "A", source: .media(items[0].id, audio: AudioSettings(volume: 0.3)))]
            self.library = library
            coordinator.onError = { XCTFail($0.localizedDescription) }
        }

        func close() {
            factory.surfaces.forEach { $0.surface.finishPrepare(); $0.surface.finishClose() }
            coordinator.shutdown()
        }
    }

    @MainActor private final class RecordingFactory: SurfaceMaking {
        var surfaces: [(mediaID: UUID, surface: ControlledSurface)] = []
        var holdPrepare = false
        var prepareError: Error?

        func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
            let surface = ControlledSurface()
            surface.holdPrepare = holdPrepare
            surface.prepareError = prepareError
            surfaces.append((item.id, surface))
            return surface
        }
    }
}
