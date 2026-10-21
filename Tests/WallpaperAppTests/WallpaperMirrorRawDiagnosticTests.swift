import AppKit
import AVFoundation
import ScreenCaptureKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperMirrorRawDiagnosticTests: XCTestCase {
    func testOwnDesktopVideoContinuesBehindNativeFullScreenWithoutCapturingForeground() async throws {
        try await captureVideo(enterFullScreen: true, startInsideFullScreen: true)
    }

    func testOwnDesktopVideoKeepsUpdatingWithoutChangingSpaces() async throws {
        try await captureVideo(enterFullScreen: false)
    }

    private func captureVideo(enterFullScreen: Bool, startInsideFullScreen: Bool = false) async throws {
        let fixture = try SettingsPresentationFixture { _ in AnyView(Color.purple.ignoresSafeArea()) }
        defer { fixture.close() }
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        try await fixture.showWindow()
        let screen = try XCTUnwrap(fixture.window.screen)
        let desktop = DesktopWindow(screen: screen)
        let url = try await VideoIntegrationTests.makeVideo()
        defer { desktop.shutdown(); try? FileManager.default.removeItem(at: url) }
        let item = try await MediaProbe.inspect(url)
        try await desktop.prepare(item: item, fit: .fill, entry: PlaylistEntry(mediaID: item.id))
        let result = await desktop.transition(duration: 0, paused: false)
        XCTAssertTrue(result.didDisplay)
        if startInsideFullScreen {
            try await WallpaperMirrorTestSupport.setFullScreen(true, window: fixture.window)
        }

        let content: SCShareableContent
        if #available(macOS 14.4, *) { content = try await SCShareableContent.currentProcess }
        else { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        let source = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(desktop.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.minimumFrameInterval = .zero
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        let recorder = PlaybackTimingRecorder()
        let queue = DispatchQueue(label: "wallpaper-mirror-capture-test")
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: source),
                              configuration: configuration, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        do {
            try await WallpaperMirrorTestSupport.waitUntil(description: "Pre-fullscreen video frames") {
                recorder.snapshot().video.count >= 3
            }
            logState("before-fullscreen", desktop: desktop, recorder: recorder)
            if enterFullScreen { try await WallpaperMirrorTestSupport.setFullScreen(true, window: fixture.window) }
            else { try await Task.sleep(for: .seconds(1)) }
            let enteredAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            logState("entered-fullscreen", desktop: desktop, recorder: recorder)
            try await WallpaperMirrorTestSupport.waitUntil(description: "Video frames from the desktop Space") {
                let fresh = recorder.snapshot().video.filter { $0.displayHost > enteredAt }
                return fresh.count >= 6 && (fresh.last?.displayHost ?? 0) >= enteredAt + 1.5
            }
            let snapshot = recorder.snapshot()
            let levels = snapshot.video.filter { $0.displayHost > enteredAt }.map(\.level)
            XCTAssertGreaterThan(try XCTUnwrap(levels.max()) - XCTUnwrap(levels.min()), 0.06,
                                 "Wallpaper video must keep changing in the inactive desktop Space")
            XCTAssertGreaterThan(try XCTUnwrap(levels.min()), 0.35)
            XCTAssertLessThan(try XCTUnwrap(levels.max()), 0.65,
                              "The captured pixels must come from the wallpaper video")
            XCTAssertTrue(snapshot.audio.isEmpty, "Mirror capture must not create a second audio path")
            XCTAssertTrue(snapshot.errors.isEmpty, snapshot.errors.joined(separator: "\n"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fixture.output.appendingPathComponent("fullscreen-stream.json"))
            print("Fullscreen mirror: \(configuration.width)x\(configuration.height), \(levels.count) post-transition frames")
        } catch {
            print("Fullscreen stream verification failed: \(error)")
            logState("failure", desktop: desktop, recorder: recorder)
            try JSONEncoder().encode(recorder.snapshot())
                .write(to: fixture.output.appendingPathComponent("fullscreen-stream-failure.json"))
            for index in 0..<2 {
                let image = try await WallpaperSnapshot.capture(window: desktop)
                let bitmap = NSBitmapImageRep(cgImage: image)
                let color = try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
                print("Independent screenshot \(index): red=\(color.redComponent), green=\(color.greenComponent), blue=\(color.blueComponent)")
                try await Task.sleep(for: .milliseconds(200))
            }
            try await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        let stoppedCount = recorder.snapshot().video.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.snapshot().video.count, stoppedCount)
        try await WallpaperMirrorTestSupport.setFullScreen(false, window: fixture.window)
        desktop.shutdown()
        try await desktop.waitForClosing()
        try await fixture.model.shutdownAndWait()
    }

    private func logState(_ stage: String, desktop: DesktopWindow, recorder: PlaybackTimingRecorder) {
        let player = desktop.contentView?.subviews.flatMap { $0.layer?.sublayers ?? [] }
            .compactMap { $0 as? AVPlayerLayer }.first?.player
        let snapshot = recorder.snapshot()
        print("Mirror diagnostic \(stage): appActive=\(NSApp.isActive), activeSpace=\(desktop.isOnActiveSpace), visible=\(desktop.isVisible), "
            + "occlusion=\(desktop.occlusionState.rawValue), playerTime=\(player?.currentTime().seconds ?? -1), "
            + "rate=\(player?.rate ?? -1), control=\(player?.timeControlStatus.rawValue ?? -1), "
            + "item=\(player?.currentItem.map { String(describing: ObjectIdentifier($0)) } ?? "nil"), "
            + "frames=\(snapshot.video.count), statuses=\(snapshot.frameStatuses), "
            + "errors=\(snapshot.errors)")
    }
}
