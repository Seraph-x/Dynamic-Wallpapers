@testable import WallpaperNative
import XCTest
import AppKit
import AVFoundation
import ImageIO
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class VideoIntegrationTests: XCTestCase {
    func testFailedPreparationDisposesLayersForAllCallers() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("corrupt video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let surface = MediaSurface(size: CGSize(width: 64, height: 64), fit: .fill)
        defer { surface.dispose() }
        let item = MediaItem(url: url, kind: .video, width: 64, height: 64)
        do { try await surface.prepare(item: item, scale: 1, fit: .fill, timeout: 1); XCTFail("must fail") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertTrue(surface.layer?.sublayers?.isEmpty ?? true)
        XCTAssertFalse(surface.isPlaying)
    }
    func testRealVideoProbeFirstFrameAndDisposal() async throws {
        let url = try await Self.makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await MediaProbe.inspect(url)
        XCTAssertEqual(item.kind, .video)
        XCTAssertEqual(item.width, 64)
        XCTAssertGreaterThan(try XCTUnwrap(item.duration), 0)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 256, height: 144),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = MediaSurface(size: CGSize(width: 256, height: 144), fit: .fill)
        window.contentView = surface
        window.orderBack(nil)
        defer { surface.dispose(); window.close() }
        try await surface.prepare(item: item, scale: 1, fit: .fill, timeout: 5)
        XCTAssertFalse(surface.isPlaying)
        surface.play(); XCTAssertTrue(surface.isPlaying)
        surface.pause(); XCTAssertFalse(surface.isPlaying)
        surface.dispose()
        XCTAssertNil(surface.superview)
    }

    func testCancellationOfVideoPreparationIsExplicit() async throws {
        let url = try await Self.makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await MediaProbe.inspect(url)
        let surface = MediaSurface(size: CGSize(width: 64, height: 64), fit: .fill)
        defer { surface.dispose() }
        let task = Task { try await surface.prepare(item: item, scale: 1, fit: .fill, timeout: 2) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled video must not prepare") }
        catch is CancellationError { }
    }

    static func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? WallpaperError("Fixture encoder did not start") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? WallpaperError("Fixture encoder failed") }
                try await Task.sleep(for: .milliseconds(1))
            }
            var optional: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &optional)
            XCTAssertEqual(result, kCVReturnSuccess)
            let buffer = try XCTUnwrap(optional)
            CVPixelBufferLockBaseAddress(buffer, [])
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 { for x in 0..<64 {
                let offset = y * stride + x * 4
                address[offset] = 255; address[offset + 1] = 220
                address[offset + 2] = UInt8(frame * 15); address[offset + 3] = 80
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else {
                throw writer.error ?? WallpaperError("Fixture encoder append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? WallpaperError("Fixture encoder did not finish") }
        return url
    }
}
