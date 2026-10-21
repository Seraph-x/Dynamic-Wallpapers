import XCTest
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import WallpaperCore
import WallpaperNative

@MainActor
final class NativeModuleMediaTests: XCTestCase {
    func testSharedModulePreparesPNGAndAnimatedImagesAndCloses() async throws {
        for (type, count) in [(UTType.png.identifier, 1), (UTType.gif.identifier, 2), (UTType.png.identifier, 2)] {
            let url = try MediaTests.makeImage(type: type, frames: count)
            defer { try? FileManager.default.removeItem(at: url) }
            let item = try await NativeMediaProbe.inspect(url)
            XCTAssertEqual(item.backend, .native)
            XCTAssertEqual(item.kind, count == 1 ? .image : .animatedImage)
            let surface = MediaSurface(size: CGSize(width: 32, height: 32), fit: .fit)
            addTeardownBlock { @MainActor in try await surface.close() }
            try await surface.prepare(item: item, scale: 1, fit: .fit)
            XCTAssertEqual(surface.state, .ready)
            let initial = try pixel(surface.layer?.contents)
            surface.play()
            if count > 1 {
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while try pixel(surface.layer?.contents) == initial,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertNotEqual(try pixel(surface.layer?.contents), initial)
            }
            try await surface.close()
            XCTAssertEqual(surface.state, .closed)
            XCTAssertNil(surface.layer?.contents)
            surface.play()
            XCTAssertEqual(surface.state, .closed)
        }
    }

    func testSharedModulePreparesARealVideoAndReleasesItsQueue() async throws {
        let url = try await VideoIntegrationTests.makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await NativeMediaProbe.inspect(url)
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.backend, .native)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = MediaSurface(size: window.frame.size, fit: .fit)
        addTeardownBlock { @MainActor in
            defer { window.close() }
            try await surface.close()
        }
        window.contentView = surface
        window.orderBack(nil)
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        let layer = try XCTUnwrap(surface.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        let player = try XCTUnwrap(layer.player as? AVQueuePlayer)
        XCTAssertTrue(layer.isReadyForDisplay)
        XCTAssertNotNil(player.currentItem)
        XCTAssertTrue(player.isMuted)
        try await surface.close()
        XCTAssertEqual(surface.state, .closed)
        XCTAssertNil(layer.player)
        XCTAssertNil(player.currentItem)
        XCTAssertTrue(player.items().isEmpty)
        XCTAssertNil(surface.superview)
    }

    func testNativeProbeDoesNotAdoptAnExtendedVideo() async throws {
        let video = try await VideoIntegrationTests.makeVideo()
        let extended = video.deletingPathExtension().appendingPathExtension("mkv")
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: extended)
        }
        try FileManager.default.copyItem(at: video, to: extended)
        do {
            _ = try await NativeMediaProbe.inspect(extended)
            XCTFail("Native-only probing must not route an extended video to another backend")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("无法解码"), error.localizedDescription)
        }
        XCTAssertFalse(NativeMediaProbe.fileExtensions.contains("mkv"))
    }

    private func pixel(_ contents: Any?) throws -> [UInt8] {
        let contents = try XCTUnwrap(contents)
        guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
            throw WallpaperError("Native surface did not provide CGImage pixels")
        }
        let image = contents as! CGImage
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
