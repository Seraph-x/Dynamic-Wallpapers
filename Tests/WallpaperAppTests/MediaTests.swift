@testable import WallpaperNative
import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import WallpaperApp

final class MediaTests: XCTestCase {
    func testRealPNGImportAndDownsample() async throws {
        let url = try Self.makeImage(type: UTType.png.identifier, frames: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await MediaProbe.inspect(url)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.width, 32)
        let decoder = try ImageDecoder(url: url, maxPixelSize: 16)
        let frame = try await decoder.frame(at: 0)
        XCTAssertEqual(frame.width, 16)
    }

    func testRealGIFAndAPNGTiming() async throws {
        for type in [UTType.gif.identifier, UTType.png.identifier] {
            let url = try Self.makeImage(type: type, frames: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let item = try await MediaProbe.inspect(url)
            XCTAssertEqual(item.kind, .animatedImage)
            XCTAssertEqual(try XCTUnwrap(item.duration), 0.4, accuracy: 0.02)
            let decoder = try ImageDecoder(url: url, maxPixelSize: 32)
            let frame = try await decoder.frame(at: 1)
            XCTAssertEqual(frame.width, 32)
        }
    }

    func testCorruptAndUnsupportedFilesAreExplicitErrors() async throws {
        for suffix in ["mp4", "png", "mkv"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
            try Data("invalid media".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            do { _ = try await MediaProbe.inspect(url); XCTFail("Invalid media must fail") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }

    static func makeImage(type: String, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + (type == UTType.gif.identifier ? ".gif" : ".png"))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for index in 0..<frames {
            context.setFillColor(index == 0 ? NSColor.red.cgColor : NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            let properties: [CFString: Any] = type == UTType.gif.identifier
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.2]]
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
