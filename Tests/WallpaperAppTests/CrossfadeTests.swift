import AppKit
import AVFoundation
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class CrossfadeTests: XCTestCase {
    func testNativeCrossfadeSharesVisibleProgressAndLatestAudioSettings() async throws {
        _ = NSApplication.shared
        let url = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail(error.localizedDescription) } }
        let item = try await MediaProbe.inspect(url)
        let old = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.8))
        let next = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.6))
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main))
        window.updateGeometry(frame: CGRect(x: 50, y: 50, width: 128, height: 72), scale: 1)
        window.setGlobalMute(false)
        do {
            try await window.prepare(item: item, fit: .fit, entry: old)
            _ = await window.transition(duration: 0, paused: false)
            let outgoing = try player(in: XCTUnwrap(window.contentView?.subviews.first))
            try await window.prepare(item: item, fit: .fit, entry: next)
            let incomingView = try XCTUnwrap(window.contentView?.subviews.last)
            let incoming = try player(in: incomingView)
            XCTAssertTrue(incoming.isMuted)
            let transition = Task { await window.transition(duration: 0.8, paused: false) }
            try await Task.sleep(for: .milliseconds(200))
            let progress = incomingView.alphaValue
            XCTAssertGreaterThan(progress, 0)
            XCTAssertLessThan(progress, 1)
            XCTAssertFalse(outgoing.isMuted, "Normal outgoing audio fades instead of immediate suppression")
            XCTAssertGreaterThan(outgoing.volume, 0)
            XCTAssertLessThan(outgoing.volume, 0.8)
            XCTAssertEqual(Double(outgoing.volume) / 0.8, 1 - progress, accuracy: 0.002)
            XCTAssertEqual(Double(incoming.volume) / 0.6, progress, accuracy: 0.002)
            window.setGlobalMute(true)
            XCTAssertTrue(outgoing.isMuted); XCTAssertTrue(incoming.isMuted)
            window.updateAudio([old.id: AudioSettings(volume: 0.4), next.id: AudioSettings(volume: 0.2)])
            window.setGlobalMute(false)
            XCTAssertFalse(outgoing.isMuted); XCTAssertFalse(incoming.isMuted)
            XCTAssertEqual(Double(outgoing.volume) / 0.4, 1 - progress, accuracy: 0.002)
            XCTAssertEqual(Double(incoming.volume) / 0.2, progress, accuracy: 0.002)
            window.setPaused(true)
            XCTAssertTrue(outgoing.isMuted); XCTAssertTrue(incoming.isMuted)
            let result = await transition.value
            XCTAssertTrue(result.didDisplay)
            XCTAssertNil(result.error)
            XCTAssertEqual(incomingView.alphaValue, 1)
            XCTAssertTrue(outgoing.isMuted, "The endpoint must gate outgoing audio before release")
            XCTAssertTrue(incoming.isMuted, "Pause must survive visual transition completion")
            window.setPaused(false)
            XCTAssertFalse(incoming.isMuted)
            XCTAssertEqual(incoming.volume, 0.2, accuracy: 0.001)
            XCTAssertTrue(outgoing.isMuted)
            window.shutdown()
            try await window.waitForClosing()
        } catch {
            window.shutdown()
            try await window.waitForClosing()
            throw error
        }
    }

    private func player(in view: NSView) throws -> AVPlayer {
        let layer = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        return try XCTUnwrap(layer.player)
    }
}
