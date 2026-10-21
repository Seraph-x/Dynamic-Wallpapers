import AppKit
import AVFoundation
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class CrossfadeCancellationTests: XCTestCase {
    func testCancellationHardGatesBothOutputsWhileVisibleTransitionFinishes() async throws {
        _ = NSApplication.shared
        let url = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail(error.localizedDescription) } }
        let item = try await MediaProbe.inspect(url)
        let old = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.8))
        let next = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.6))
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main))
        window.updateGeometry(frame: CGRect(x: 50, y: 50, width: 128, height: 72), scale: 1)
        window.setGlobalMute(false)
        var transition: Task<PlaybackTransitionResult, Never>?
        do {
            try await window.prepare(item: item, fit: .fit, entry: old)
            let initial = await window.transition(duration: 0, paused: false)
            XCTAssertTrue(initial.didDisplay)
            let outgoing = try player(in: XCTUnwrap(window.contentView?.subviews.first))
            try await window.prepare(item: item, fit: .fit, entry: next)
            let incomingView = try XCTUnwrap(window.contentView?.subviews.last)
            let incoming = try player(in: incomingView)
            let running = Task { await window.transition(duration: 0.8, paused: false) }
            transition = running
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertGreaterThan(incomingView.alphaValue, 0)
            XCTAssertLessThan(incomingView.alphaValue, 1)
            XCTAssertFalse(outgoing.isMuted, "Positive control: outgoing must be active before cancellation")
            XCTAssertFalse(incoming.isMuted, "Positive control: incoming must be active before cancellation")
            running.cancel()
            // Allow the cancellation handler to enter MainActor, without waiting for the fade endpoint.
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertLessThan(incomingView.alphaValue, 1, "Hard gates must take effect before visual completion")
            XCTAssertTrue(outgoing.isMuted, "Cancellation must immediately gate outgoing audio")
            XCTAssertTrue(incoming.isMuted, "Cancellation must immediately gate incoming audio")
            window.setGlobalMute(true)
            window.updateAudio([old.id: AudioSettings(volume: 0.4), next.id: AudioSettings(volume: 0.2)])
            window.setGlobalMute(false)
            XCTAssertTrue(outgoing.isMuted, "Clearing global mute cannot undo cancellation")
            XCTAssertTrue(incoming.isMuted, "New entry settings cannot undo cancellation")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(outgoing.isMuted, "Later fade ticks cannot undo cancellation")
            XCTAssertTrue(incoming.isMuted, "Later fade ticks cannot undo cancellation")
            let result = await running.value
            XCTAssertTrue(result.didDisplay, "The in-flight visual transaction still finishes")
            XCTAssertNil(result.error)
            XCTAssertEqual(incomingView.alphaValue, 1)
            XCTAssertTrue(outgoing.isMuted, "Outgoing remains gated after release")
            XCTAssertTrue(incoming.isMuted, "Visual completion cannot restart cancelled output")
            XCTAssertEqual(window.activeSurfaceCount, 1)
            window.shutdown()
            try await window.waitForClosing()
        } catch {
            window.shutdown()
            try await window.waitForClosing()
            if let transition { _ = await transition.value }
            throw error
        }
    }

    func testCancellationDuringOutgoingReleaseStillGatesIncoming() async throws {
        _ = NSApplication.shared
        let factory = ControlledFactory()
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main), surfaceFactory: factory)
        let item = MediaItem(url: URL(fileURLWithPath: "/controlled.png"), kind: .image, width: 32, height: 32)
        let entry = PlaylistEntry(mediaID: item.id)
        defer { window.shutdown() }
        try await window.prepare(item: item, fit: .fit, entry: entry)
        _ = await window.transition(duration: 0, paused: false)
        let old = factory.surfaces[0]
        old.holdClose = true
        try await window.prepare(item: item, fit: .fit, entry: entry)
        let incoming = factory.surfaces[1]
        let transition = Task { await window.transition(duration: 0, paused: false) }
        await fulfillment(of: [old.closeStarted], timeout: 1)
        XCTAssertTrue(incoming.playing)
        XCTAssertFalse(incoming.suppressed, "Positive control before cancellation")
        transition.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(incoming.suppressed, "Cancellation while awaiting old release must hard gate incoming")
        old.finishClose()
        let result = await transition.value
        XCTAssertTrue(result.didDisplay)
        XCTAssertNil(result.error)
        XCTAssertTrue(incoming.suppressed, "Release completion must not restart cancelled output")
        window.shutdown()
        try await window.waitForClosing()
    }

    private func player(in view: NSView) throws -> AVPlayer {
        let layer = try XCTUnwrap(view.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        return try XCTUnwrap(layer.player)
    }
}
