import CoreGraphics
import XCTest
@testable import WallpaperApp

@MainActor
final class MediaThumbnailTests: XCTestCase {
    func testWebThumbnailUsesALaterRenderedFrameInsteadOfTheFirstPaint() async throws {
        let frames = try [red, green, blue].map(makeImage)
        var index = 0

        let result = try await MediaThumbnail.settledWebFrame(requiredChanges: 2, maximumSamples: 4,
            currentFrame: { frames[index] }, waitForNextSample: {
                index = min(index + 1, frames.count - 1)
            })

        XCTAssertTrue(result === frames[2])
    }

    func testStaticWebThumbnailReturnsTheAvailableFrameAfterTheSamplingBudget() async throws {
        let frame = try makeImage(red)
        var samples = 0

        let result = try await MediaThumbnail.settledWebFrame(requiredChanges: 2, maximumSamples: 3,
            currentFrame: { frame }, waitForNextSample: { samples += 1 })

        XCTAssertTrue(result === frame)
        XCTAssertEqual(samples, 3)
    }

    private let red = (UInt8(255), UInt8(0), UInt8(0), UInt8(255))
    private let green = (UInt8(0), UInt8(255), UInt8(0), UInt8(255))
    private let blue = (UInt8(0), UInt8(0), UInt8(255), UInt8(255))

    private func makeImage(_ color: (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        let bytes = [color.0, color.1, color.2, color.3]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
