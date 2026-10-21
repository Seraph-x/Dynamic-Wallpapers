import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import XCTest

@MainActor
enum WindowCompositorCapture {
    static func capture(_ window: NSWindow, to url: URL) async throws -> NSBitmapImageRep {
        XCTAssertTrue(window.isVisible)
        let screen = try XCTUnwrap(window.screen)
        let screenID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let display = try XCTUnwrap(content.displays.first { $0.displayID == screenID })
        _ = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let frame = window.frame
        XCTAssertTrue(screen.frame.contains(frame), "Compositor capture requires the whole test window to be onscreen")
        let configuration = SCStreamConfiguration()
        configuration.width = Int(frame.width * 2)
        configuration.height = Int(frame.height * 2)
        // SCWindow.frame can lag after a resize. Use live AppKit geometry so
        // the cropped pixels line up with the controls' accessibility frames.
        configuration.sourceRect = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY,
                                          width: frame.width, height: frame.height)
        configuration.showsCursor = false
        // Keep quantization stable for subtle tints across displays with different ICC profiles.
        configuration.colorSpaceName = CGColorSpace.sRGB
        // Window-filtered captures lose behind-window sampling and glass vibrancy.
        // Capture the real compositor, restricted to our test window's rectangle.
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return NSBitmapImageRep(cgImage: image)
    }
}
