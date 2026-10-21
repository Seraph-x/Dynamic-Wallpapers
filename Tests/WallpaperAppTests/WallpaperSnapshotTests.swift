@testable import WallpaperNative
import AppKit
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperSnapshotTests: XCTestCase {
    func testCaptureIncludesLayerChangesMadeImmediatelyBeforeRequest() async throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 90))
        view.wantsLayer = true
        let window = makeWindow(view)
        defer { window.close() }
        for color in [NSColor.red, .blue, .green] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.backgroundColor = color.cgColor
            CATransaction.commit()
            let actual = try centerColor(await WallpaperSnapshot.capture(window: window))
            let expected = try XCTUnwrap(color.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.05)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.05)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.05)
        }
    }

    func testNativeVideoCapturesRealPixelsWithoutPausingAndKeepsTheImageFrozen() async throws {
        let url = try await VideoIntegrationTests.makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await MediaProbe.inspect(url)
        let surface = MediaSurface(size: CGSize(width: 160, height: 90), fit: .fit)
        let window = makeWindow(surface.view)
        defer { surface.dispose(); window.close() }
        try await surface.prepare(item: item, scale: 1, fit: .fit, timeout: 5)
        surface.play()
        let image = try await WallpaperSnapshot.capture(window: window)
        let first = try centerColor(image)
        XCTAssertGreaterThan(first.redComponent, 0.6, "A video layer must produce the encoded frame, not black")
        XCTAssertEqual(surface.state, .playing)
        try await Task.sleep(for: .milliseconds(350))
        let later = try centerColor(await WallpaperSnapshot.capture(window: window))
        XCTAssertGreaterThan(abs(later.greenComponent - first.greenComponent), 0.05)
        XCTAssertEqual(try centerColor(image), first, "Already captured pixels must remain immutable")
        XCTAssertEqual(surface.state, .playing)
        try await surface.close()
    }

    func testExtendedVideoCaptureExcludesCoveringWindows() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/dependencies/mpv/fixtures")
        let item = MediaItem(url: root.appendingPathComponent("h264-aac.mkv"), kind: .video,
            width: 320, height: 180, duration: 2, backend: .extended)
        let surface = MPVSurface(size: CGSize(width: 320, height: 180), fit: .fit)
        let window = makeWindow(surface.view)
        let cover = makeWindow(NSView(frame: surface.bounds))
        cover.backgroundColor = .magenta
        cover.setFrame(window.frame, display: true)
        defer { window.close(); cover.close() }
        do {
            try await surface.prepare(item: item, scale: 1, fit: .fit)
            let expected = try centerColor(await WallpaperSnapshot.capture(window: window))
            cover.order(.above, relativeTo: window.windowNumber)
            let image = try await WallpaperSnapshot.capture(window: window)
            let actual = try centerColor(image)
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.05)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.05)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.05)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let samples = try [0.1, 0.3, 0.7, 0.9].map {
                try bitmap.sRGBColor(atX: Int(Double(bitmap.pixelsWide) * $0), y: bitmap.pixelsHigh / 5).redComponent
            }
            XCTAssertGreaterThan(try XCTUnwrap(samples.max()) - XCTUnwrap(samples.min()), 0.4,
                                 "The capture must contain the real video pattern")
            XCTAssertEqual(surface.state, .ready)
            try await surface.close()
        } catch {
            try await surface.close()
            throw error
        }
    }

    func testSystemImagePreservesFitFillColorAndRetinaResolution() throws {
        let image = NSImage(size: CGSize(width: 20, height: 10), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let output = try WallpaperSnapshot.renderSystemImage(image, size: CGSize(width: 40, height: 40), scale: 2,
            options: [.allowClipping: false, .fillColor: NSColor.blue])
        XCTAssertEqual(output.width, 80)
        XCTAssertEqual(output.height, 80)
        let bitmap = NSBitmapImageRep(cgImage: output)
        XCTAssertGreaterThan(try bitmap.sRGBColor(atX: 40, y: 40).redComponent, 0.9)
        XCTAssertGreaterThan(try bitmap.sRGBColor(atX: 40, y: 5).blueComponent, 0.9)
        let filled = try WallpaperSnapshot.renderSystemImage(image, size: CGSize(width: 40, height: 40), scale: 2,
            options: [.allowClipping: true, .fillColor: NSColor.blue])
        XCTAssertGreaterThan(try NSBitmapImageRep(cgImage: filled).sRGBColor(atX: 40, y: 5).redComponent, 0.9)
    }

    func testInvalidSystemImageGeometryAndScalingAreExplicitErrors() throws {
        let image = NSImage(size: CGSize(width: 20, height: 10))
        XCTAssertThrowsError(try WallpaperSnapshot.renderSystemImage(image, size: .zero, scale: 2, options: [:]))
        XCTAssertThrowsError(try WallpaperSnapshot.renderSystemImage(image, size: CGSize(width: 20, height: 20),
                                                                    scale: .infinity, options: [:]))
        XCTAssertThrowsError(try WallpaperSnapshot.renderSystemImage(image, size: CGSize(width: 20, height: 20),
            scale: 1, options: [.imageScaling: NSNumber(value: UInt.max)]))
    }

    private func makeWindow(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: content.bounds.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Match DesktopWindow: opening animations must not affect captured pixel comparisons.
        window.animationBehavior = .none
        window.contentView = content
        window.orderBack(nil)
        return window
    }

    private func centerColor(_ image: CGImage) throws -> NSColor {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
    }
}
