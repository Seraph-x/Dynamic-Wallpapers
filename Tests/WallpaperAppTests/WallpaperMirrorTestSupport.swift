import AppKit
import AVFoundation
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
enum WallpaperMirrorTestSupport {
    static func sampleBuffer() throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
        let buffer = try XCTUnwrap(image)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    static func mirrorView(in window: NSWindow) -> WallpaperMirrorView? {
        func find(_ view: NSView) -> WallpaperMirrorView? {
            if let mirror = view as? WallpaperMirrorView { return mirror }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    static func setFullScreen(_ enabled: Bool, window: NSWindow) async throws {
        if window.styleMask.contains(.fullScreen) == enabled { return }
        var finished = false
        let name = enabled ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { finished = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.toggleFullScreen(nil)
        try await waitUntil(timeout: 6, description: "Native fullscreen transition") { finished }
        XCTAssertEqual(window.styleMask.contains(.fullScreen), enabled)
    }

    static func waitUntil(timeout: Double = 3, description: String,
                          condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while try !condition() {
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                              inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard ContinuousClock.now < deadline else { throw WallpaperError("\(description) timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
