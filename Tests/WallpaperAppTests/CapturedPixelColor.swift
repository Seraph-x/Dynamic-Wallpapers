import AppKit
import XCTest

extension NSBitmapImageRep {
    func sRGBColor(atX x: Int, y: Int) throws -> NSColor {
        let pixel = try XCTUnwrap(colorAt(x: x, y: y))
        var components = [CGFloat](repeating: 0, count: pixel.numberOfComponents)
        pixel.getComponents(&components)
        // colorAt labels RGB components as Generic RGB even when the bitmap embeds an ICC profile.
        let sourceSpace = try XCTUnwrap(colorSpace.cgColorSpace)
        let tagged = try XCTUnwrap(CGColor(colorSpace: sourceSpace, components: components))
        return try XCTUnwrap(NSColor(cgColor: tagged)?.usingColorSpace(.sRGB))
    }
}
