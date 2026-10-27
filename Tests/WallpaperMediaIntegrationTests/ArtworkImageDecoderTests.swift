import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

final class ArtworkImageDecoderTests: XCTestCase {
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("MediaAutomationHarness/Fixtures/owned-artwork.png")
    }
    static let identity = SystemMediaArtworkIdentity(source: .music, trackID: "owned-0")

    func testRealPNGPreservesActualDimensionsPixelsAndIdentity() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let artifact = try ArtworkImageDecoder.decode(data, for: Self.identity)
        XCTAssertEqual(artifact.identity, Self.identity)
        XCTAssertEqual(artifact.width, 2); XCTAssertEqual(artifact.height, 1)
        XCTAssertEqual(try Self.pixels(artifact.pngData), [255, 0, 0, 255, 0, 0, 255, 255])
        XCTAssertEqual(try Data(contentsOf: Self.fixtureURL), data, "Normalization must not modify original bytes")
    }

    func testActualTIFFOrientationNormalizesToPNGWithoutResizing() throws {
        let png = try Data(contentsOf: Self.fixtureURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let tiff = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let artifact = try ArtworkImageDecoder.decode(tiff as Data, for: Self.identity)
        XCTAssertEqual(artifact.width, 1); XCTAssertEqual(artifact.height, 2)
        let normalized = try XCTUnwrap(CGImageSourceCreateWithData(artifact.pngData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(normalized) as String?, UTType.png.identifier)
        XCTAssertEqual(try Self.pixels(artifact.pngData), [255, 0, 0, 255, 0, 0, 255, 255])
    }

    func testInvalidAndTruncatedImagesFailExplicitly() throws {
        for bytes in [Data(), Data("not an image".utf8), try Data(contentsOf: Self.fixtureURL).prefix(30)] {
            XCTAssertThrowsError(try ArtworkImageDecoder.decode(bytes, for: Self.identity)) { error in
                guard case SystemMediaArtworkError.invalidImage = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    static func pixels(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
