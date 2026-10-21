import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SystemWallpaperSourceVersionTests: XCTestCase {
    func testEnablingAfterFileReplacementCannotCacheOldRedPixelsAsTheNewBlueSource() async throws {
        let fixture = try SystemWallpaperAppFixture(bound: true)
        addTeardownBlock { @MainActor in try await fixture.close() }
        let model = fixture.model
        try await fixture.wait { model.statuses.values.contains { $0.hasPrefix("正在播放") } }
        let blue = NSBitmapImageRep(cgImage: try SystemWallpaperFiles.image(red: 0))
        try XCTUnwrap(blue.representation(using: .png, properties: [:])).write(to: fixture.files.item.url, options: .atomic)
        XCTAssertTrue(model.setSystemWallpaperSyncEnabled(true))
        await model.systemWallpaperSync.waitForPendingOperations()
        XCTAssertTrue(fixture.setter.attempts.isEmpty, "Old loaded pixels must not be attributed to the new file version")
        guard case .failed(let failure) = model.systemWallpaperSync.states[fixture.screenID] else {
            return XCTFail("Changed source must report the need to apply the wallpaper again")
        }
        XCTAssertTrue(failure.summary.contains("素材"))
        XCTAssertNil(model.failure, "Version mismatch must not stop normal wallpaper playback")
        model.systemWallpaperSync.retry(displayID: fixture.screenID)
        await model.systemWallpaperSync.waitForPendingOperations()
        XCTAssertTrue(fixture.setter.attempts.isEmpty, "Retry cannot recertify an old decoded instance")
        model.applyMedia(fixture.files.item, displayID: fixture.screenID, fit: .fill)
        try await fixture.wait { fixture.setter.attempts.count == 1 }
        let poster = try await fixture.syncedImage()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: poster)))
        XCTAssertGreaterThan(try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2).blueComponent, 0.9)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: poster.deletingLastPathComponent().path).count, 1)
    }

    func testSourceChangeDuringPreparationFailsOnlySyncNotPlayback() async throws {
        try await assertPreparationVersionFailure(missingBeforePreparation: false)
    }

    func testReapplyingSymbolicLinkAfterTargetChangesExportsTheActualNewPixels() async throws {
        let files = try SystemWallpaperFiles()
        addTeardownBlock { try files.remove() }
        let red = NSBitmapImageRep(cgImage: try SystemWallpaperFiles.image())
        try XCTUnwrap(red.representation(using: .png, properties: [:])).write(to: files.item.url)
        let alias = files.root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: files.item.url)
        let item = MediaItem(url: alias, kind: .image, width: 8, height: 6)
        let fixture = try SystemWallpaperAppFixture(enabled: true, bound: true, item: item)
        addTeardownBlock { @MainActor in try await fixture.close() }
        let before = try await fixture.syncedImage()
        let blue = NSBitmapImageRep(cgImage: try SystemWallpaperFiles.image(red: 0))
        try XCTUnwrap(blue.representation(using: .png, properties: [:])).write(to: files.item.url, options: .atomic)
        fixture.model.applyMedia(item, displayID: fixture.screenID, fit: .fill)
        let after = try await fixture.syncedImage(after: 2)
        XCTAssertNotEqual(before, after)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: after)))
        XCTAssertGreaterThan(try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2).blueComponent, 0.9)
    }

    func testFailedVersionReadCannotBeRecertifiedAfterTheFileReappears() async throws {
        try await assertPreparationVersionFailure(missingBeforePreparation: true)
    }

    private func assertPreparationVersionFailure(missingBeforePreparation: Bool) async throws {
        let files = try SystemWallpaperFiles()
        var captures = 0, writes = 0
        let source = DesktopWallpaperSource(capture: { window in
            captures += 1
            return try SystemWallpaperFiles.image(width: Int((window.frame.width * window.backingScaleFactor).rounded()),
                                                  height: Int((window.frame.height * window.backingScaleFactor).rounded()))
        })
        let fixture = try DesktopPreviewFixture(systemWallpaperSource: source)
        let sync = SystemWallpaperSync(store: files.store, capture: source.capture, isCurrent: source.isCurrent,
                                       apply: { _, _ in writes += 1 })
        source.onChange = { [weak sync] in sync?.updateTargets($0) }
        addTeardownBlock { @MainActor in
            sync.shutdown(); fixture.close()
            await sync.waitForPendingOperations()
            try await fixture.coordinator.waitForShutdown()
            try files.remove()
        }
        fixture.library.media = [files.item]
        fixture.library.displays[0].source = .media(files.item.id, audio: AudioSettings())
        if missingBeforePreparation { try FileManager.default.removeItem(at: files.item.url) }
        else { fixture.factory.configure = { $0.holdPrepare = true } }
        fixture.coordinator.reconcile(fixture.library)
        if !missingBeforePreparation {
            try await fixture.wait { fixture.factory.records.count == 1 }
            let surface = try XCTUnwrap(fixture.factory.records.first?.surface)
            await fulfillment(of: [surface.prepareStarted], timeout: 2)
            try Data("changed during actual surface preparation".utf8).write(to: files.item.url, options: .atomic)
            surface.finishPrepare()
        }
        try await fixture.wait { fixture.commits.count == 1 }
        if missingBeforePreparation {
            try Data("reappeared after the surface finished loading".utf8).write(to: files.item.url)
        }
        XCTAssertTrue(fixture.errors.isEmpty)
        XCTAssertTrue(fixture.factory.records[0].surface.playing)
        sync.setEnabled(true)
        await sync.waitForPendingOperations()
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(writes, 0)
        guard case .failed = sync.states["A"] else { return XCTFail("Unverified loaded source was accepted") }
        sync.retry(displayID: "A")
        await sync.waitForPendingOperations()
        XCTAssertEqual(writes, 0)
    }
}
