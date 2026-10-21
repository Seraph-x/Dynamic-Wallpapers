import AppKit
import XCTest
@testable import WallpaperApp
import WallpaperCore

@MainActor
final class ExtendedPlaybackTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/dependencies/mpv/fixtures")
    }

    func testThreeContainersPrepareRealSilentFramesAndMetadata() async throws {
        for name in ["h264-aac.mkv", "vp9-opus.webm", "mpeg4-mp3.avi"] {
            let surface = MPVSurface(size: CGSize(width: 320, height: 180), fit: .fit)
            let item = MediaItem(url: fixtureRoot.appendingPathComponent(name), kind: .video,
                                 width: 320, height: 180, duration: 2, backend: .extended)
            do {
                try await surface.prepare(item: item, scale: 1, fit: .fit)
                XCTAssertEqual(surface.state, .ready)
                XCTAssertGreaterThan(surface.committedFrameCount, 0)
                XCTAssertNotNil(surface.currentImage)
                let image = try XCTUnwrap(surface.currentImage)
                let bitmap = NSBitmapImageRep(cgImage: image)
                let pixels = try XCTUnwrap(bitmap.bitmapData)
                let red = stride(from: 0, to: bitmap.bytesPerRow * bitmap.pixelsHigh, by: bitmap.samplesPerPixel).map { pixels[$0] }
                XCTAssertGreaterThan(Int(try XCTUnwrap(red.max())) - Int(try XCTUnwrap(red.min())), 20,
                                     "The known fixture must have decoded test-pattern pixels, not initial black.")
                XCTAssertEqual(surface.metadata?.width, 320)
                XCTAssertEqual(surface.metadata?.height, 180)
                XCTAssertGreaterThan(surface.metadata?.duration ?? 0, 1.5)
                let decoder = try XCTUnwrap(surface.metadata?.hardwareDecoder)
                XCTAssertTrue(["no", "videotoolbox-copy"].contains(decoder), decoder)
                print("Actual decoder: \(name) = \(decoder)")
                if name == "h264-aac.mkv" { XCTAssertEqual(decoder, "videotoolbox-copy") }
                if name == "mpeg4-mp3.avi" { XCTAssertEqual(decoder, "no") }
                XCTAssertTrue(try surface.audioIsMuted())
                surface.play() // Global mute remains true throughout the real test.
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertTrue(try surface.audioIsMuted())
                surface.pause()
                let paused = try surface.playbackPosition()
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(try surface.playbackPosition(), paused, accuracy: 0.05)
                try await surface.close()
                XCTAssertEqual(surface.state, .closed)
            } catch {
                try await surface.close()
                throw error
            }
        }
    }

    func testCorruptMediaFailsAndReleases() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mkv")
        try Data("not a media container".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let surface = MPVSurface(size: CGSize(width: 64, height: 64), fit: .fill)
        do {
            try await surface.prepare(item: MediaItem(url: url, kind: .video, width: 64,
                height: 64, duration: 2, backend: .extended), scale: 1, fit: .fill)
            XCTFail("Corrupt bytes must fail")
        } catch { XCTAssertNotNil(error as Error?) }
        try await surface.close()
        XCTAssertEqual(surface.state, .closed)
    }

    func testCloseDuringPreparationRejectsLateFrameAndIsIdempotent() async throws {
        let surface = MPVSurface(size: CGSize(width: 320, height: 180), fit: .fit)
        let item = MediaItem(url: fixtureRoot.appendingPathComponent("h264-aac.mkv"),
                            kind: .video, width: 320, height: 180, duration: 2, backend: .extended)
        let preparation = Task { try await surface.prepare(item: item, scale: 1, fit: .fit) }
        await Task.yield()
        try await surface.close()
        do { try await preparation.value; XCTFail("Close must cancel in-flight preparation") }
        catch is CancellationError { }
        XCTAssertEqual(surface.state, .closed)
        let frames = surface.committedFrameCount
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(surface.committedFrameCount, frames)
        XCTAssertNil(surface.currentImage)
        try await surface.close()
    }

    func testCancelledAndTimedOutPreparationCloseBeforeReturning() async throws {
        let item = MediaItem(url: fixtureRoot.appendingPathComponent("h264-aac.mkv"), kind: .video,
                             width: 320, height: 180, duration: 2, backend: .extended)
        let cancelled = MPVSurface(size: CGSize(width: 320, height: 180), fit: .fit)
        let task = Task { try await cancelled.prepare(item: item, scale: 1, fit: .fit) }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must fail") } catch is CancellationError { }
        XCTAssertEqual(cancelled.state, .closed)
        XCTAssertEqual(cancelled.committedFrameCount, 0)
        let timedOut = MPVSurface(size: CGSize(width: 320, height: 180), fit: .fit)
        do {
            try await timedOut.prepare(item: item, scale: 1, fit: .fit, timeout: 0.000001)
            XCTFail("Preparation should exceed an explicit one-microsecond deadline")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("视频加载超时"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("h264-aac.mkv"))
        }
        XCTAssertEqual(timedOut.state, .closed)
        XCTAssertNil(timedOut.currentImage)
    }

    func testRealPlaybackLoopsAndVolumeChangesWithoutRecreatingSurface() async throws {
        let surface = MPVSurface(size: CGSize(width: 160, height: 90), fit: .fill)
        let item = MediaItem(url: fixtureRoot.appendingPathComponent("h264-aac.mkv"), kind: .video,
                             width: 320, height: 180, duration: 2, backend: .extended)
        do {
            try await surface.prepare(item: item, scale: 1, fit: .fill)
            surface.setAudio(AudioSettings(volume: 0.27))
            surface.play()
            XCTAssertEqual(try surface.playbackVolume(), 0.27, accuracy: 0.0001)
            XCTAssertTrue(try surface.audioIsMuted()) // Never change system or other process audio.
            var previous = try surface.playbackPosition()
            var loops = 0
            let deadline = ContinuousClock.now + .seconds(6)
            while loops < 2 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
                let position = try surface.playbackPosition()
                if position < previous - 0.5 { loops += 1 }
                previous = position
            }
            XCTAssertEqual(loops, 2)
            XCTAssertGreaterThan(surface.committedFrameCount, 50)
            surface.setAudio(AudioSettings(volume: 0.73))
            XCTAssertEqual(try surface.playbackVolume(), 0.73, accuracy: 0.0001)
            XCTAssertTrue(try surface.audioIsMuted())
            surface.pause()
            try await surface.close()
        } catch { try await surface.close(); throw error }
    }

    func testDisguisedPlaylistIsRejectedBeforeDecoderStarts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mkv")
        try Data("#EXTM3U\nhttps://invalid.example/blocked.mp4\n".utf8).write(to: url)
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail(error.localizedDescription) } }
        XCTAssertThrowsError(try ExtendedMediaProbe.validateURL(url))
    }

    func testProbeReturnsExtendedBackendAfterRealDecode() async throws {
        let item = try await ExtendedMediaProbe.inspect(fixtureRoot.appendingPathComponent("vp9-opus.webm"))
        XCTAssertEqual(item.backend, .extended)
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.width, 320)
        XCTAssertEqual(item.height, 180)
    }

    func testRejectsNetworkAndNativeRoute() async throws {
        do {
            _ = try await ExtendedMediaProbe.inspect(URL(string: "https://example.com/video.mkv")!)
            XCTFail("Network source must fail")
        } catch { }
        let surface = MPVSurface(size: CGSize(width: 64, height: 64), fit: .fit)
        do {
            try await surface.prepare(item: MediaItem(url: fixtureRoot.appendingPathComponent("h264-aac.mkv"),
                kind: .video, width: 64, height: 64, duration: 2), scale: 1, fit: .fit)
            XCTFail("Native backend must not be silently rerouted")
        } catch { }
        try await surface.close()
    }
}
