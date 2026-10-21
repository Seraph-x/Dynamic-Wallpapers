@testable import WallpaperNative
import XCTest
import SwiftUI
import AVFoundation
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class PreviewAudioTests: XCTestCase {
    func testPreviewUpdatesEntryAudioAndAlwaysHonorsGlobalMute() async throws {
        _ = NSApplication.shared
        let url = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail(error.localizedDescription) } }
        let item = try await MediaProbe.inspect(url)
        let lifetime = PreviewLifetime()
        let host = NSHostingView(rootView: preview(item, audio: AudioSettings(volume: 0.3), muted: true, lifetime: lifetime))
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 300, height: 188),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        try await waitUntil { self.findSurface(host)?.isPlaying == true }
        let surface = try XCTUnwrap(findSurface(host))
        let layer = try XCTUnwrap(surface.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        let player = try XCTUnwrap(layer.player)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.volume, 0.3, accuracy: 0.001)
        host.rootView = preview(item, audio: AudioSettings(volume: 0.7), muted: false, lifetime: lifetime)
        try await waitUntil { !player.isMuted && abs(player.volume - 0.7) < 0.001 }
        XCTAssertTrue(findSurface(host) === surface)
        host.rootView = preview(item, audio: AudioSettings(isMuted: true, volume: 0.2), muted: false, lifetime: lifetime)
        try await waitUntil { player.isMuted && abs(player.volume - 0.2) < 0.001 }
        host.rootView = preview(item, audio: AudioSettings(volume: 0.8), muted: true, lifetime: lifetime)
        try await waitUntil { player.isMuted && abs(player.volume - 0.8) < 0.001 }
        XCTAssertTrue(findSurface(host) === surface)
        try await lifetime.closeAll()
    }

    private func preview(_ item: MediaItem, audio: AudioSettings, muted: Bool, lifetime: PreviewLifetime) -> LivePreview {
        LivePreview(item: item, audio: audio, globallyMuted: muted, lifetime: lifetime,
                    onError: { XCTFail($0.localizedDescription) })
    }
    private func findSurface(_ view: NSView) -> MediaSurface? {
        if let surface = view as? MediaSurface { return surface }
        return view.subviews.lazy.compactMap { self.findSurface($0) }.first
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Preview state update timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
