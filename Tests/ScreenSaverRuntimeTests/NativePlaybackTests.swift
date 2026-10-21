import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import XCTest
import ScreenSaverCore
import WallpaperCore
import WallpaperNative
@testable import ScreenSaverRuntime

@MainActor
final class NativePlaybackTests: XCTestCase {
    func testRealGIFAndAPNGPixelsAdvanceAndStopClearsEveryFrame() async throws {
        for type in ["com.compuserve.gif", "public.png"] {
            let f = try await RuntimeFixture(test: self)
            _ = try await f.publish(type: type, frames: 2)
            var surfaces: [MediaSurface] = []
            let session = f.makeSession { size, fit in
                let surface = MediaSurface(size: size, fit: fit); surfaces.append(surface); return surface
            }
            session.start()
            try await eventually { session.state.phase == .playing }
            let surface = try XCTUnwrap(surfaces.first)
            let first = try pixels(surface)
            try await eventually { try self.pixels(surface) != first }
            try await session.stop().value
            XCTAssertNil(surface.layer?.contents)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(surface.layer?.contents, "No late animation frame may reappear after close")
            XCTAssertNil(surface.superview)
        }
    }

    func testRealVideoPixelsAndAudioPolicyStopWithTheSession() async throws {
        let f = try await RuntimeFixture(test: self)
        let url = try await RuntimeVideoFixture.makeVideo()
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        try await f.publishVideo(url)
        var surfaces: [MediaSurface] = []
        let session = f.makeSession { size, fit in
            let surface = MediaSurface(size: size, fit: fit); surfaces.append(surface); return surface
        }
        session.start()
        try await eventually { session.state.phase == .playing }
        let layer = try XCTUnwrap(surfaces[0].layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        XCTAssertTrue(layer.isReadyForDisplay)
        let player = try XCTUnwrap(layer.player)
        XCTAssertFalse(player.isMuted)
        let playing = try XCTUnwrap(player.currentItem)
        let firstPixel = try await displayedPixel(layer, surface: surfaces[0])
        let firstTime = playing.currentTime().seconds
        try await eventually { playing.currentTime().seconds - firstTime >= 3.0 / 12 }
        var laterPixel = try await displayedPixel(layer, surface: surfaces[0])
        let frameDeadline = ContinuousClock.now + .seconds(3)
        while laterPixel == firstPixel && ContinuousClock.now < frameDeadline {
            try await Task.sleep(for: .milliseconds(100))
            laterPixel = try await displayedPixel(layer, surface: surfaces[0])
        }
        XCTAssertNotEqual(firstPixel, laterPixel, "The actual displayed video frame must change")
        try await eventually { player.currentItem !== playing }
        let stopped = session.stop()
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(f.view.subviews.isEmpty)
        try await stopped.value
        XCTAssertNil(layer.player)
        XCTAssertNil(player.currentItem)
        XCTAssertTrue(surfaces[0].layer?.sublayers?.isEmpty ?? true)
        XCTAssertNil(layer.superlayer)
        // The detached layer applies its nil-player transaction on the render loop.
        try await eventually { layer.displayedPixelBuffer() == nil }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(layer.displayedPixelBuffer(), "No late video frame may reappear after close")
        for context in [ScreenSaverAudioContext.systemPreview, .systemDisplay(isMain: false), .systemDisplay(isMain: nil)] {
            var native: MediaSurface?
            let silent = f.makeSession(context: context) { size, fit in
                let surface = MediaSurface(size: size, fit: fit); native = surface; return surface
            }
            silent.start()
            try await eventually { silent.state.phase == .playing }
            let outputLayer = try XCTUnwrap(native?.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
            XCTAssertTrue(try XCTUnwrap(outputLayer.player).isMuted)
            XCTAssertNotNil(silent.state.audio?.reason)
            try await silent.stop().value
        }
    }

    private func displayedPixel(_ layer: AVPlayerLayer, surface: MediaSurface) async throws -> Data {
        // AVPlayerLayer exposes its real displayed buffer only while paused. Unlike adding a
        // second AVPlayerItemVideoOutput during playback, this does not reconfigure decoding.
        surface.pause()
        defer { surface.play() }
        var buffer: CVPixelBuffer?
        try await eventually { buffer = layer.displayedPixelBuffer(); return buffer != nil }
        let image = CIImage(cvPixelBuffer: try XCTUnwrap(buffer))
        let decoded = try XCTUnwrap(CIContext().createCGImage(image, from: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        return (try XCTUnwrap(decoded.dataProvider?.data) as Data).prefix(4)
    }

    private func pixels(_ surface: MediaSurface) throws -> Data {
        let contents = try XCTUnwrap(surface.layer?.contents)
        guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { throw WallpaperError("Expected an actual decoded image") }
        let image = contents as! CGImage
        let bytes = try XCTUnwrap(image.dataProvider?.data)
        return bytes as Data
    }
}
