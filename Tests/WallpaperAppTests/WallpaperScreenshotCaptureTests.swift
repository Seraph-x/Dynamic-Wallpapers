import AppKit
import AVFoundation
import Combine
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperScreenshotCaptureTests: XCTestCase {
    func testDefaultScreenshotMirrorMovesAndExitKeepsOriginalDesktopPlayer() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Displayed-pixel readback requires macOS 14.4") }
        let fixture = try SettingsPresentationFixture { _ in AnyView(Color.purple) }
        defer { fixture.close() }
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        try await fixture.showWindow()
        let screen = try XCTUnwrap(fixture.window.screen)
        let desktop = DesktopWindow(screen: screen)
        let url = try await VideoIntegrationTests.makeVideo()
        defer {
            desktop.shutdown()
            do { try FileManager.default.removeItem(at: url) }
            catch { XCTFail("Screenshot fixture removal failed: \(error)") }
        }
        let item = try await MediaProbe.inspect(url)
        let initial = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let mirror = WallpaperMirrorSession(source: { WallpaperMirrorSource(window: desktop) },
            systemWallpaper: { initial }, changes: Empty().eraseToAnyPublisher())
        fixture.window.contentView = mirror.view
        var failures: [Error] = []
        mirror.onFailure = { failures.append($0) }
        let closeObservation = ScreenshotCloseObservation()
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification,
            object: fixture.window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    closeObservation.began = ProcessInfo.processInfo.systemUptime
                    let close = mirror.beginClose()
                    closeObservation.task = Task {
                        try await close.value
                        closeObservation.ended = ProcessInfo.processInfo.systemUptime
                    }
                }
            }
        defer { NotificationCenter.default.removeObserver(token) }
        do {
            try await desktop.prepare(item: item, fit: .fill, entry: PlaylistEntry(mediaID: item.id))
            let transition = await desktop.transition(duration: 0, paused: false)
            XCTAssertTrue(transition.didDisplay)
            let originalPlayer = try player(in: desktop)
            try await WallpaperMirrorTestSupport.setFullScreen(true, window: fixture.window)
            let startBegan = ProcessInfo.processInfo.systemUptime
            try await mirror.start(initialImage: initial)
            let startMilliseconds = (ProcessInfo.processInfo.systemUptime - startBegan) * 1000
            try await WallpaperMirrorTestSupport.waitUntil(description: "Screenshot mirror received real frames") {
                if let failure = failures.first { throw failure }
                return (mirror.statistics?.receivedFrames ?? 0) >= 4
            }
            var green: [Double] = []
            for _ in 0..<16 {
                green.append(try greenPixel(mirror.view))
                try await Task.sleep(for: .milliseconds(80))
            }
            let stats = try XCTUnwrap(mirror.statistics)
            let dimensions = try pixelDimensions(mirror.view)
            XCTAssertEqual(dimensions.width, Int(screen.frame.width * screen.backingScaleFactor))
            XCTAssertEqual(dimensions.height, Int(screen.frame.height * screen.backingScaleFactor))
            XCTAssertTrue(stats.frameStatuses.isEmpty, "Default mirror must use pull capture, not SCStream delegate callbacks")
            XCTAssertGreaterThan(try XCTUnwrap(green.max()) - XCTUnwrap(green.min()), 0.15)
            XCTAssertGreaterThan(stats.receivedFrames, 12)
            _ = try await WindowCompositorCapture.capture(fixture.window,
                to: fixture.output.appendingPathComponent("screenshot-mirror-visible.png"))
            try await WallpaperMirrorTestSupport.setFullScreen(false, window: fixture.window)
            try await XCTUnwrap(closeObservation.task).value
            XCTAssertTrue(mirror.isClosed)
            XCTAssertTrue(try player(in: desktop) === originalPlayer)
            var playerTimes: [Double] = []
            for _ in 0..<20 {
                XCTAssertEqual(originalPlayer.rate, 1)
                XCTAssertNotEqual(originalPlayer.timeControlStatus, .paused)
                playerTimes.append(originalPlayer.currentTime().seconds)
                try await Task.sleep(for: .milliseconds(30))
            }
            let advancing = zip(playerTimes, playerTimes.dropFirst()).filter { abs($1 - $0) > 0.005 }.count
            XCTAssertGreaterThanOrEqual(advancing, 15, "Closing the mirror must not pause its original source player")
            let record: [String: Any] = ["startCompletionMilliseconds": startMilliseconds,
                "closeMilliseconds": (closeObservation.ended - closeObservation.began) * 1000,
                "receivedFrames": stats.receivedFrames,
                "greenSamples": green, "sourceTimesAfterExit": playerTimes,
                "advancingSourceIntervalsAfterExit": advancing, "sameOriginalPlayer": true,
                "physicalDisplaySmoothnessProven": false]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: fixture.output.appendingPathComponent("screenshot-mirror-exit.json"))
            print("Screenshot mirror: startCompleted=\(startMilliseconds)ms close=\((closeObservation.ended-closeObservation.began)*1000)ms sourceClockIntervals=\(advancing)/19 evidence=\(fixture.output.path)")
        } catch { failures.append(error) }
        do { try await mirror.beginClose().value } catch { failures.append(error) }
        do { try await WallpaperMirrorTestSupport.setFullScreen(false, window: fixture.window) }
        catch { failures.append(error) }
        desktop.shutdown()
        do { try await desktop.waitForClosing(); try await fixture.model.shutdownAndWait() }
        catch { failures.append(error) }
        if failures.count == 1 { throw failures[0] }
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
    }

    private func player(in desktop: DesktopWindow) throws -> AVPlayer {
        try XCTUnwrap(desktop.contentView?.subviews.flatMap { $0.layer?.sublayers ?? [] }
            .compactMap { $0 as? AVPlayerLayer }.first?.player)
    }

    @available(macOS 14.4, *)
    private func pixelDimensions(_ view: WallpaperMirrorView) throws -> (width: Int, height: Int) {
        let buffer = try XCTUnwrap(view.videoLayer.sampleBufferRenderer.displayedPixelBuffer())
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        return (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    }

    @available(macOS 14.4, *)
    private func greenPixel(_ view: WallpaperMirrorView) throws -> Double {
        let buffer = try XCTUnwrap(view.videoLayer.sampleBufferRenderer.displayedPixelBuffer())
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let offset = CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer)
            + CVPixelBufferGetWidth(buffer) / 2 * 4
        return Double(base[offset + 1]) / 255
    }
}

@MainActor
private final class ScreenshotCloseObservation {
    var task: Task<Void, Error>?
    var began = 0.0
    var ended = 0.0
}
