import AppKit
import XCTest

final class CapturedPixelColorTests: XCTestCase {
    func testSRGBBitmapPreservesTheRequestedColor() throws {
        let bitmap = try bitmap(space: CGColorSpace.sRGB, rgba: [191, 226, 255, 255])
        let expected = NSColor(srgbRed: 191.0 / 255, green: 226.0 / 255, blue: 1, alpha: 1)
        try assertColor(bitmap, equals: expected)
    }

    func testDisplayP3BitmapUsesItsEmbeddedProfile() throws {
        let bitmap = try bitmap(space: CGColorSpace.displayP3, rgba: [102, 153, 204, 255])
        let expected = try XCTUnwrap(NSColor(displayP3Red: 0.4, green: 0.6, blue: 0.8, alpha: 1)
            .usingColorSpace(.sRGB))
        try assertColor(bitmap, equals: expected)
    }

    private func bitmap(space: CFString, rgba: [UInt8]) throws -> NSBitmapImageRep {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: try XCTUnwrap(CGColorSpace(name: space)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSBitmapImageRep(cgImage: image)
    }

    private func assertColor(_ bitmap: NSBitmapImageRep, equals expected: NSColor,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for image in [bitmap, try XCTUnwrap(NSBitmapImageRep(data: png))] {
            let actual = try image.sRGBColor(atX: 0, y: 0)
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.0001, file: file, line: line)
        }
    }
}
