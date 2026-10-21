import AppKit
import AVFoundation
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperFrameRateIntegrationTests: XCTestCase {
    func testRestoredAndEditedRatesControlRealCaptureWithoutReplacingPlayback() async throws {
        let fixture = try SettingsPresentationFixture { _ in AnyView(Color.purple) }
        defer { fixture.close() }
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        try await fixture.showWindow()
        let screen = try XCTUnwrap(fixture.window.screen)
        let screenID = try XCTUnwrap(screen.wallpaperID)
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let url = try await VideoIntegrationTests.makeVideo()
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { XCTFail("Rate fixture removal failed: \(error)") }
        }
        let media = try await MediaProbe.inspect(url)
        var saved = fixture.model.library
        saved.settings.appearance.fullScreenFrameRate = .hz60
        saved.media = [media]
        saved.displays = [DisplayBinding(id: screenID, source: .media(media.id,
            audio: AudioSettings(isMuted: true, volume: 0.42)))]
        try await fixture.model.shutdownAndWait()
        try fixture.model.store.save(saved)
        let model = AppModel(store: fixture.model.store)
        defer { model.shutdown() }
        XCTAssertFalse(model.loadFailed)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Rate fixture desktop playback") {
            if let failure = model.failure { throw failure }
            return model.statuses.values.contains { $0.hasPrefix("正在播放") }
        }
        let desktop = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let originalPlayer = try player(in: desktop)
        let originalVolume = originalPlayer.volume, originalMuted = originalPlayer.isMuted
        let mirror = try model.makeWallpaperMirror(on: screen)
        fixture.window.contentView = mirror.view
        var failures: [Error] = []
        do {
            try await WallpaperMirrorTestSupport.setFullScreen(true, window: fixture.window)
            try await mirror.start(initialImage: model.captureWallpaper(on: screen))
            var samples: [CadenceSample] = []
            samples.append(try await measure(mirror, rate: .hz60, phase: "restored-60"))
            for rate in [WallpaperMirrorFrameRate.hz30, .hz60] {
                var appearance = model.library.settings.appearance
                appearance.fullScreenFrameRate = rate
                XCTAssertTrue(model.setAppearance(appearance))
                XCTAssertEqual(try model.store.load().settings.appearance.fullScreenFrameRate, rate)
                samples.append(try await measure(mirror, rate: rate, phase: "edited-\(rate.rawValue)"))
            }
            let beforeFailure = model.library
            try FileManager.default.removeItem(at: model.store.url)
            try FileManager.default.createDirectory(at: model.store.url, withIntermediateDirectories: false)
            var rejected = model.library.settings.appearance
            rejected.fullScreenFrameRate = .hz30
            XCTAssertFalse(model.setAppearance(rejected))
            XCTAssertEqual(model.library, beforeFailure)
            XCTAssertNotNil(model.appearanceFailure)
            samples.append(try await measure(mirror, rate: .hz60, phase: "failed-save-keeps-60"))
            try FileManager.default.removeItem(at: model.store.url)
            try model.store.save(beforeFailure)

            let thirty = samples[1].receivedFramesPerSecond
            XCTAssertGreaterThan(thirty, 20)
            for sample in [samples[0], samples[2], samples[3]] {
                XCTAssertGreaterThan(sample.receivedFramesPerSecond, thirty * 1.4, sample.phase)
            }
            XCTAssertTrue(fixture.window.contentView === mirror.view)
            XCTAssertTrue(try player(in: desktop) === originalPlayer)
            XCTAssertEqual(originalPlayer.rate, 1)
            XCTAssertEqual(originalPlayer.volume, originalVolume)
            XCTAssertEqual(originalPlayer.isMuted, originalMuted)
            XCTAssertFalse(mirror.isClosed)
            XCTAssertNil(mirror.failure)
            try JSONEncoder().encode(samples).write(to: fixture.output.appendingPathComponent("mirror-frame-rates.json"))
            print("Real mirror receive cadence (not display FPS): \(samples); evidence=\(fixture.output.path)")
        } catch { failures.append(error) }
        do { try await mirror.beginClose().value } catch { failures.append(error) }
        do { try await WallpaperMirrorTestSupport.setFullScreen(false, window: fixture.window) }
        catch { failures.append(error) }
        do { try await model.shutdownAndWait() } catch { failures.append(error) }
        if failures.count == 1 { throw failures[0] }
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
    }

    private struct CadenceSample: Codable {
        let phase: String
        let requestedHertz: Int
        let receivedFrames: Int
        let elapsedSeconds: Double
        var receivedFramesPerSecond: Double { Double(receivedFrames) / elapsedSeconds }
    }

    private func measure(_ mirror: WallpaperMirrorSession, rate: WallpaperMirrorFrameRate,
                         phase: String) async throws -> CadenceSample {
        // Exclude the single wait already scheduled before the setting changed.
        try await Task.sleep(for: .milliseconds(100))
        if let failure = mirror.failure { throw failure }
        let before = try XCTUnwrap(mirror.statistics).receivedFrames
        let start = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(700))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if let failure = mirror.failure { throw failure }
        let after = try XCTUnwrap(mirror.statistics).receivedFrames
        return CadenceSample(phase: phase, requestedHertz: rate.rawValue,
                             receivedFrames: after - before, elapsedSeconds: elapsed)
    }

    private func player(in window: DesktopWindow) throws -> AVPlayer {
        try XCTUnwrap(window.contentView?.subviews.flatMap { $0.layer?.sublayers ?? [] }
            .compactMap { $0 as? AVPlayerLayer }.first?.player)
    }
}
