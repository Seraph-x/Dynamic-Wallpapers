import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperMirrorCaptureTests: XCTestCase {
    private enum SourceKind { case nativeVideo, extendedVideo, animatedImage }
    private struct FrameEvidence: Encodable {
        let elapsed: Double
        let red: Double
        let green: Double
        let blue: Double
        let width: Int
        let height: Int
        let enqueued: Int
        let pending: Int
    }

    func testOwnDesktopVideoContinuesBehindNativeFullScreenWithoutCapturingForeground() async throws {
        try await verifyPlayback(.nativeVideo, fullScreen: true, checkPause: true)
    }

    func testOwnDesktopVideoKeepsUpdatingWithoutChangingSpaces() async throws {
        try await verifyPlayback(.nativeVideo, fullScreen: false)
    }

    func testExtendedVideoRendersThroughTheFullScreenMirror() async throws {
        try await verifyPlayback(.extendedVideo, fullScreen: true)
    }

    func testAnimatedImageRendersThroughTheFullScreenMirror() async throws {
        try await verifyPlayback(.animatedImage, fullScreen: true)
    }

    private func verifyPlayback(_ kind: SourceKind, fullScreen: Bool, checkPause: Bool = false) async throws {
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("Rendered pixel-buffer readback requires macOS 14.4; capture itself supports macOS 14.")
        }
        let fixture = try SettingsPresentationFixture { _ in AnyView(Color.purple.ignoresSafeArea()) }
        defer { fixture.close() }
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        try await fixture.showWindow()
        let screen = try XCTUnwrap(fixture.window.screen)
        let desktop = DesktopWindow(screen: screen)
        let item = try await makeItem(kind)
        defer { desktop.shutdown(); try? FileManager.default.removeItem(at: item.url) }
        let view = WallpaperMirrorView()
        view.frame = fixture.window.contentView?.bounds ?? .zero
        fixture.window.contentView = view
        var stream: WallpaperMirrorStream?
        var failures: [Error] = []
        let began = ProcessInfo.processInfo.systemUptime
        let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    print("Space diagnostic: \(kind) t=\(ProcessInfo.processInfo.systemUptime - began), active=\(fixture.window.isOnActiveSpace)")
                }
            }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        do {
            try await desktop.prepare(item: item, fit: .fill, entry: PlaylistEntry(mediaID: item.id))
            let transition = await desktop.transition(duration: 0, paused: false)
            XCTAssertTrue(transition.didDisplay)
            if fullScreen { try await WallpaperMirrorTestSupport.setFullScreen(true, window: fixture.window) }
            print("didEnter diagnostic: \(kind) t=\(ProcessInfo.processInfo.systemUptime - began), active=\(fixture.window.isOnActiveSpace), source=\(desktop.windowNumber)")
            let capture = try await WallpaperMirrorStream.make(window: desktop, view: view)
            stream = capture
            var failure: Error?
            capture.onFailure = { failure = $0 }
            try await capture.start()
            print("start diagnostic: \(kind) t=\(ProcessInfo.processInfo.systemUptime - began), sourceActive=\(desktop.isOnActiveSpace)")
            try await WallpaperMirrorTestSupport.waitUntil(description: "Product mirror displayed a real frame") {
                if let failure { throw failure }
                return view.videoLayer.sampleBufferRenderer.displayedPixelBuffer() != nil
            }
            let frames = try await sampleFrames(view: view, stream: capture, failure: { failure })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(frames).write(to: fixture.output.appendingPathComponent("product-mirror-frames.json"))
            print("Before sampling assertions: \(kind) fullscreen=\(fullScreen) stats=\(capture.output.statistics)")
            let varying = frames.map { kind == .animatedImage ? $0.red : $0.green }
            XCTAssertGreaterThan(try XCTUnwrap(varying.max()) - XCTUnwrap(varying.min()), 0.15,
                                 "The displayed mirror must change well after the native Space transition")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames.last).elapsed, 1.5)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames.last).enqueued - XCTUnwrap(frames.first).enqueued, 6)
            XCTAssertTrue(frames.allSatisfy { $0.pending <= 1 })
            let expectedSize = screen.convertRectToBacking(CGRect(origin: .zero, size: desktop.frame.size)).size
            XCTAssertTrue(frames.allSatisfy { $0.width == Int(expectedSize.width) && $0.height == Int(expectedSize.height) })
            if kind != .animatedImage {
                XCTAssertTrue(frames.allSatisfy { (0.75...0.95).contains($0.red) && (0.2...0.4).contains($0.blue) },
                              "Purple foreground pixels must not enter the desktop-window capture")
            }
            let bitmap = try await WindowCompositorCapture.capture(fixture.window,
                to: fixture.output.appendingPathComponent("product-mirror-visible.png"))
            let color = try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
            if kind != .animatedImage { XCTAssertEqual(color.redComponent, 220.0 / 255, accuracy: 0.08) }
            if checkPause { try await verifyPauseAndResume(desktop: desktop, view: view, stream: capture) }
            if let failure { throw failure }
            print("Product mirror: \(kind), fullscreen=\(fullScreen), \(frames[0].width)x\(frames[0].height), "
                + "displayed samples=\(frames.count), enqueued=\(capture.output.statistics.enqueuedFrames), "
                + "replaced=\(capture.output.statistics.replacedFrames), max pending=\(frames.map(\.pending).max() ?? 0)")
        } catch {
            if let stream {
                print("Mirror failure stats: \(stream.output.statistics), renderer=\(view.videoLayer.sampleBufferRenderer.status.rawValue)")
                for _ in 0..<2 {
                    let image = try await WallpaperSnapshot.capture(window: desktop)
                    let pixels = NSBitmapImageRep(cgImage: image)
                    let color = try pixels.sRGBColor(atX: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)
                    print("Source screenshot after failure: \(color)")
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            failures.append(error)
        }
        if let stream {
            do { try await stream.beginClose().value } catch { failures.append(error) }
            XCTAssertEqual(stream.output.statistics.pendingFrames, 0)
            XCTAssertFalse(stream.output.isAcceptingFrames)
            print("Close readback immediate: \(view.videoLayer.sampleBufferRenderer.displayedPixelBuffer() != nil)")
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))
            print("Close readback after CA commit: \(view.videoLayer.sampleBufferRenderer.displayedPixelBuffer() != nil)")
            XCTAssertNil(view.videoLayer.sampleBufferRenderer.displayedPixelBuffer())
        }
        do { try await WallpaperMirrorTestSupport.setFullScreen(false, window: fixture.window) }
        catch { failures.append(error) }
        desktop.shutdown()
        do { try await desktop.waitForClosing(); try await fixture.model.shutdownAndWait() }
        catch { failures.append(error) }
        if failures.count == 1 { throw failures[0] }
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
    }

    @available(macOS 14.4, *)
    private func sampleFrames(view: WallpaperMirrorView, stream: WallpaperMirrorStream,
                              failure: () -> Error?) async throws -> [FrameEvidence] {
        let began = ProcessInfo.processInfo.systemUptime
        var frames: [FrameEvidence] = []
        for _ in 0..<9 {
            if let error = failure() { throw error }
            frames.append(try sampleFrame(view: view, stream: stream, began: began))
            try await Task.sleep(for: .milliseconds(220))
        }
        return frames
    }

    @available(macOS 14.4, *)
    private func sampleFrame(view: WallpaperMirrorView, stream: WallpaperMirrorStream, began: Double) throws -> FrameEvidence {
        // Release the retained IOSurface readback before suspending the test.
        let buffer = try XCTUnwrap(view.videoLayer.sampleBufferRenderer.displayedPixelBuffer())
        let color = try pixel(buffer)
        let stats = stream.output.statistics
        return FrameEvidence(elapsed: ProcessInfo.processInfo.systemUptime - began,
            red: color[0], green: color[1], blue: color[2], width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer), enqueued: stats.enqueuedFrames, pending: stats.pendingFrames)
    }

    @available(macOS 14.4, *)
    private func verifyPauseAndResume(desktop: DesktopWindow, view: WallpaperMirrorView,
                                      stream: WallpaperMirrorStream) async throws {
        desktop.setPaused(true)
        try await Task.sleep(for: .milliseconds(200))
        let paused = try pixel(XCTUnwrap(view.videoLayer.sampleBufferRenderer.displayedPixelBuffer()))
        try await Task.sleep(for: .milliseconds(300))
        let still = try pixel(XCTUnwrap(view.videoLayer.sampleBufferRenderer.displayedPixelBuffer()))
        XCTAssertEqual(paused[1], still[1], accuracy: 0.01, "Pause must keep the last actual wallpaper frame")
        let before = stream.output.statistics.enqueuedFrames
        try await desktop.prepareToResume(requestID: UUID())
        desktop.setPaused(false)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Mirror resumes with its original player") {
            stream.output.statistics.enqueuedFrames >= before + 3
        }
    }

    private func pixel(_ buffer: CVPixelBuffer) throws -> [Double] {
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let offset = CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer)
            + CVPixelBufferGetWidth(buffer) / 2 * 4
        return [Double(base[offset + 2]), Double(base[offset + 1]), Double(base[offset])].map { $0 / 255 }
    }

    private func makeItem(_ kind: SourceKind) async throws -> MediaItem {
        if kind == .animatedImage { return try await MediaProbe.inspect(makeAnimation()) }
        let url = try await VideoIntegrationTests.makeVideo()
        let native = try await MediaProbe.inspect(url)
        if kind == .nativeVideo { return native }
        let extended = url.deletingPathExtension().appendingPathExtension("mkv")
        do { try await TranscodeTestFixtures.ffmpeg(["-i", url.path, "-c", "copy", extended.path]) }
        catch { try FileManager.default.removeItem(at: url); throw error }
        try FileManager.default.removeItem(at: url)
        return MediaItem(url: extended, kind: .video, width: native.width, height: native.height,
                         duration: native.duration, backend: .extended)
    }

    private func makeAnimation() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for color in [NSColor.red, .blue] {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
