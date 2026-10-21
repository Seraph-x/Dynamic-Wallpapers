@testable import WallpaperNative
import XCTest
import AppKit
import AVFoundation
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class AudioPlaybackTests: XCTestCase {
    func testCoordinatorAppliesEntryVolumeAndGlobalMuteWithoutRestart() async throws {
        try await verifyCoordinatorAudio(direct: false)
    }

    func testCoordinatorAppliesDirectVolumeAndGlobalMuteWithoutRestart() async throws {
        try await verifyCoordinatorAudio(direct: true)
    }

    private func verifyCoordinatorAudio(direct: Bool) async throws {
        _ = NSApplication.shared
        let url = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail(error.localizedDescription) } }
        let item = try await MediaProbe.inspect(url)
        var library = Library.empty
        library.media = [item]
        library.settings.isMuted = false
        library.playlists[0].entries = [PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.35))]
        library.playlists[0].transition = 0
        let source: DisplaySource = direct ? .media(item.id, audio: AudioSettings(volume: 0.35)) : .playlist(library.playlists[0].id)
        library.displays = [DisplayBinding(id: try XCTUnwrap(NSScreen.main?.wallpaperID), source: source)]
        if direct { library.playlists = [] }
        let coordinator = DesktopCoordinator()
        defer { coordinator.shutdown() }
        let committed = expectation(description: "first frame committed")
        coordinator.onCommit = { _, _ in committed.fulfill() }
        coordinator.onError = { XCTFail($0.localizedDescription) }
        coordinator.reconcile(library)
        await fulfillment(of: [committed], timeout: 2)
        let window = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }.first { $0.isVisible })
        let surface = try XCTUnwrap(window.contentView?.subviews.first as? MediaSurface)
        let player = try player(on: surface)
        let playingItem = player.currentItem
        XCTAssertFalse(player.isMuted)
        XCTAssertEqual(player.volume, 0.35, accuracy: 0.001)
        library.settings.isMuted = true
        coordinator.reconcile(library)
        XCTAssertTrue(player.isMuted)
        if direct { library.displays[0].source = .media(item.id, audio: AudioSettings(volume: 0.6)) }
        else { library.playlists[0].entries[0].audio.volume = 0.6 }
        coordinator.reconcile(library)
        XCTAssertTrue(player.isMuted, "Entry changes cannot override global mute")
        library.settings.isMuted = false
        coordinator.reconcile(library)
        XCTAssertFalse(player.isMuted)
        XCTAssertEqual(player.volume, 0.6, accuracy: 0.001)
        if direct { library.displays[0].source = .media(item.id, audio: AudioSettings(isMuted: true, volume: 0.6)) }
        else { library.playlists[0].entries[0].audio.isMuted = true }
        coordinator.reconcile(library)
        XCTAssertTrue(player.isMuted)
        XCTAssertTrue(player.currentItem === playingItem)
        XCTAssertTrue(surface.isPlaying)
    }

    func testCompletedScreenKeepsIncomingAudioBeforeGroupCommit() async throws {
        let url = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail(error.localizedDescription) } }
        let item = try await MediaProbe.inspect(url)
        let oldAudio = AudioSettings(volume: 0.8)
        let nextAudio = AudioSettings(isMuted: true, volume: 0.2)
        let oldEntry = PlaylistEntry(mediaID: item.id, audio: oldAudio)
        let nextEntry = PlaylistEntry(mediaID: item.id, audio: nextAudio)
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main))
        window.updateGeometry(frame: CGRect(x: 50, y: 50, width: 128, height: 72), scale: 1)
        defer { window.shutdown() }
        window.setGlobalMute(false)
        try await window.prepare(item: item, fit: .fill, entry: oldEntry)
        _ = await window.transition(duration: 0, paused: false)
        let oldSurface = try XCTUnwrap(window.contentView?.subviews.first as? MediaSurface)
        let oldPlayer = try player(on: oldSurface)
        try await window.prepare(item: item, fit: .fill, entry: nextEntry)
        let surface = try XCTUnwrap(window.contentView?.subviews.last as? MediaSurface)
        let player = try player(on: surface)
        XCTAssertTrue(player.isMuted, "Preloading remains silent")
        let transition = Task { await window.transition(duration: 0.2, paused: false) }
        let deadline = ContinuousClock.now + .seconds(1)
        while !surface.isPlaying {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Transition did not start") }
            try await Task.sleep(for: .milliseconds(1))
        }
        window.updateAudio([oldEntry.id: oldAudio, nextEntry.id: AudioSettings(volume: 0.4)])
        XCTAssertFalse(oldPlayer.isMuted, "Normal outgoing audio follows the fade until its endpoint")
        XCTAssertFalse(player.isMuted)
        window.setGlobalMute(true)
        XCTAssertTrue(player.isMuted)
        window.setGlobalMute(false)
        window.setPaused(true)
        window.updateAudio([oldEntry.id: oldAudio, nextEntry.id: AudioSettings(volume: 0.4)])
        XCTAssertEqual(player.rate, 0)
        window.setPaused(false)
        XCTAssertFalse(oldPlayer.isMuted)
        XCTAssertFalse(player.isMuted)
        let result = await transition.value
        XCTAssertTrue(result.didDisplay)
        XCTAssertNil(result.error)
        // This screen has finished; the group cursor still describes old -> next.
        window.updateAudio([oldEntry.id: oldAudio, nextEntry.id: nextAudio])
        XCTAssertTrue(player.isMuted, "The incoming entry must not inherit outgoing audio")
        XCTAssertEqual(player.volume, 0.2, accuracy: 0.001)
    }

    private func player(on surface: MediaSurface) throws -> AVPlayer {
        let layer = try XCTUnwrap(surface.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        return try XCTUnwrap(layer.player)
    }
}
