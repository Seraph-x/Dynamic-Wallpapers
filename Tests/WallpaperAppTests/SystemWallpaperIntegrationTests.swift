import AppKit
import AVFoundation
import Combine
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SystemWallpaperIntegrationTests: XCTestCase {
    func testRealFormalWindowExportsFullResolutionAndRetainsPosterAfterDisableStopAndExit() async throws {
        let fixture = try SystemWallpaperAppFixture(bound: true, fit: .fit)
        addTeardownBlock { @MainActor in try await fixture.close() }
        let model = fixture.model
        try await fixture.wait { model.statuses.values.contains { $0.hasPrefix("正在播放") } }
        XCTAssertTrue(fixture.setter.attempts.isEmpty)
        var playbackChanges = 0
        let observer = model.$statuses.dropFirst().sink { _ in playbackChanges += 1 }
        defer { observer.cancel() }
        XCTAssertTrue(model.setSystemWallpaperSyncEnabled(true))
        let url = try await fixture.syncedImage()
        XCTAssertEqual(playbackChanges, 0, "Changing the flag must not reconcile playback")
        XCTAssertEqual(url.deletingLastPathComponent(), fixture.files.root.appendingPathComponent("SystemWallpapers"))
        XCTAssertEqual(fixture.setter.attempts.first?.displayID, fixture.screenID)
        XCTAssertEqual(fixture.setter.attempts.first?.savedEnabled, true)
        let data = try Data(contentsOf: url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, Int((fixture.screen.frame.width * fixture.screen.backingScaleFactor).rounded()))
        XCTAssertEqual(bitmap.pixelsHigh, Int((fixture.screen.frame.height * fixture.screen.backingScaleFactor).rounded()))
        XCTAssertGreaterThan(try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2).redComponent, 0.9)
        let wider = bitmap.pixelsWide * 6 > bitmap.pixelsHigh * 8
        if bitmap.pixelsWide * 6 != bitmap.pixelsHigh * 8 {
            let margin = try bitmap.sRGBColor(atX: wider ? 0 : bitmap.pixelsWide / 2,
                                             y: wider ? bitmap.pixelsHigh / 2 : 0)
            XCTAssertLessThan(margin.redComponent, 0.05, "Fit margins must remain black in the actual exported image")
        }
        XCTAssertTrue(model.setSystemWallpaperSyncEnabled(false))
        model.stopDisplay(fixture.screenID)
        try await model.shutdownAndWait()
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(fixture.setter.attempts.count, 1, "Disable, stop and exit must never restore the old wallpaper")
    }

    func testRestoredEnableSynchronizesAndRepeatedSourceReusesPosterWhileFitChangesItsKey() async throws {
        let fixture = try SystemWallpaperAppFixture(enabled: true, bound: true)
        addTeardownBlock { @MainActor in try await fixture.close() }
        let first = try await fixture.syncedImage()
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: first.path)
        fixture.model.applyMedia(fixture.files.item, displayID: fixture.screenID, fit: .fill)
        let second = try await fixture.syncedImage(after: 2)
        XCTAssertEqual(first, second)
        let reusedAttributes = try FileManager.default.attributesOfItem(atPath: second.path)
        XCTAssertEqual(originalAttributes[.systemFileNumber] as? NSNumber, reusedAttributes[.systemFileNumber] as? NSNumber)
        fixture.model.applyMedia(fixture.files.item, displayID: fixture.screenID, fit: .fit)
        let fitted = try await fixture.syncedImage(after: 3)
        XCTAssertNotEqual(first, fitted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fitted.deletingLastPathComponent().path).count, 2)
    }

    func testEnablingDuringBluePreviewStillExportsRedFormalWallpaper() async throws {
        let fixture = try SystemWallpaperAppFixture(bound: true)
        addTeardownBlock { @MainActor in try await fixture.close() }
        let model = fixture.model
        try await fixture.wait { model.statuses.values.contains { $0.hasPrefix("正在播放") } }
        let url = fixture.files.root.appendingPathComponent("blue-preview.png")
        let blue = NSBitmapImageRep(cgImage: try SystemWallpaperFiles.image(red: 0))
        try XCTUnwrap(blue.representation(using: .png, properties: [:])).write(to: url)
        let item = MediaItem(url: url, kind: .image, width: 8, height: 6)
        let id = UUID()
        _ = try await model.previewLifetime.prepare(.init(id: id, item: item, size: CGSize(width: 80, height: 60),
            scale: 1, fit: .fill, desktopTarget: DesktopPreviewTarget(displayID: fixture.screenID, fit: .fill)),
            configure: { _ in }, onError: { XCTFail("Preview failed: \($0)") })
        try await model.previewLifetime.play(id)
        XCTAssertTrue(model.setSystemWallpaperSyncEnabled(true))
        let poster = try await fixture.syncedImage()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: poster)))
        let color = try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        XCTAssertGreaterThan(color.redComponent, 0.9)
        XCTAssertLessThan(color.blueComponent, 0.05)
        try await model.previewLifetime.stop(id)?.value
        await model.systemWallpaperSync.waitForPendingOperations()
        XCTAssertEqual(fixture.setter.attempts.count, 1)
    }

    func testRealVideoLoopPauseSelectionAndAudioDoNotResynchronizeOrReplacePlayer() async throws {
        _ = NSApplication.shared
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let video = try await VideoIntegrationTests.makeVideo()
        addTeardownBlock { try FileManager.default.removeItem(at: video) }
        let item = try await MediaProbe.inspect(video)
        let fixture = try SystemWallpaperAppFixture(enabled: true, bound: true, item: item)
        addTeardownBlock { @MainActor in try await fixture.close() }
        let model = fixture.model
        _ = try await fixture.syncedImage()
        let window = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
            .first { !existing.contains(ObjectIdentifier($0)) })
        let player = try player(in: window)
        let initialItem = try XCTUnwrap(player.currentItem)
        try await fixture.wait { player.currentItem !== initialItem }
        XCTAssertEqual(player.rate, 1)
        model.selectedMediaID = item.id
        model.togglePause()
        let group = try XCTUnwrap(model.library.displays.first?.groupID)
        model.updateDirectAudio(AudioSettings(isMuted: true, volume: 0.25), groupID: group)
        XCTAssertTrue(model.mutate { $0.settings.isMuted = true })
        model.next()
        model.togglePause()
        try await fixture.wait { player.rate == 1 }
        await model.systemWallpaperSync.waitForPendingOperations()
        XCTAssertTrue(try self.player(in: window) === player)
        XCTAssertEqual(fixture.setter.attempts.count, 1)
    }

    private func player(in window: DesktopWindow) throws -> AVPlayer {
        try XCTUnwrap(window.contentView?.subviews.flatMap { $0.layer?.sublayers ?? [] }
            .compactMap { $0 as? AVPlayerLayer }.first?.player)
    }
}
