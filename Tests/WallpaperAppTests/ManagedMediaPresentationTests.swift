import AppKit
import SwiftUI
import WebWallpaperBridge
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ManagedMediaPresentationTests: XCTestCase {
    func testStorageClearRequiresConfirmationAndShowsItsConfigurationBackup() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let item = try await importImage(into: fixture)
        let before = fixture.model.library
        let bytes = try Data(contentsOf: fixture.model.store.url)
        try await fixture.show()
        try await fixture.selectTab("存储与素材")
        XCTAssertTrue(fixture.contains("新导入的文件会复制到应用的 Media 目录，网页会复制整个项目；移动或删除原文件不影响副本播放。"))
        try await requestClear(in: fixture)
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertNil(fixture.model.lastLibraryBackup)
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        _ = try button("取消", in: sheet).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet == nil }
        XCTAssertEqual(try Data(contentsOf: fixture.model.store.url), bytes)

        try await requestClear(in: fixture)
        _ = try button("备份并清空", in: XCTUnwrap(fixture.window.attachedSheet)).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet == nil }
        await fixture.model.waitForMediaRemovals()
        try await fixture.settle()
        let backup = try XCTUnwrap(fixture.model.lastLibraryBackup)
        let backupDirectory = backup.deletingLastPathComponent()
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertTrue(fixture.contains("最近配置备份"))
        XCTAssertTrue(fixture.contains("备份文件夹"))
        XCTAssertTrue(fixture.contains(backupDirectory.path))
        XCTAssertFalse(fixture.contains(backup.path))
        XCTAssertEqual(fixture.model.library.settings, before.settings)
        XCTAssertTrue(fixture.model.library.media.isEmpty)
        XCTAssertTrue(fixture.model.library.playlists.isEmpty)
        XCTAssertTrue(fixture.model.library.displays.isEmpty)
        XCTAssertTrue(fixture.model.library.pendingMediaDeletions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.origin).url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        try await fixture.model.shutdownAndWait()
    }

    func testStorageShowsFailedCleanupInsteadOfClaimingFilesWereDeleted() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let item = try await importImage(into: fixture)
        let directory = item.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: directory.path)
        defer {
            do { try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: directory.path) }
            catch { XCTFail("Could not release immutable fixture: \(error)") }
        }
        fixture.model.removeMedia(item.id)
        await fixture.model.waitForMediaRemovals()
        try await fixture.show()
        try await fixture.selectTab("存储与素材")
        XCTAssertTrue(fixture.contains("待清理副本：1"))
        XCTAssertTrue(fixture.contains("部分托管副本未能清理；记录已保留，下次启动时重试。"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        try await fixture.model.shutdownAndWait()
    }

    func testQuitDismissesClearConfirmationWithoutChangingTheLibrary() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let delegate = AppDelegate()
        defer { _ = delegate }
        let before = fixture.model.library
        try await fixture.show()
        try await fixture.selectTab("存储与素材")
        try await requestClear(in: fixture)
        NotificationCenter.default.post(name: .DWApplicationWillRequestTermination, object: NSApp)
        try await wait { fixture.window.attachedSheet == nil }
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertNil(fixture.model.lastLibraryBackup)
        try await fixture.model.shutdownAndWait()
    }

    func testManagedTranscodeSuggestsTheOriginalFolderAndRecognizesImportedOutput() async throws {
        let fixture = try SettingsPresentationFixture(content: { AnyView(TranscodeView(model: $0)) })
        defer { fixture.close() }
        let source = fixture.output.appendingPathComponent("source.mkv")
        try FileManager.default.copyItem(at: TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv"), to: source)
        fixture.model.importURLs([source])
        try await wait { !fixture.model.importing }
        XCTAssertNil(fixture.model.failure)
        let item = try XCTUnwrap(fixture.model.library.media.first)
        let transcode = fixture.model.transcoding
        transcode.select(item)
        try await wait { !transcode.isProbing }
        try await fixture.show(readyText: "视频转码")
        try await wait { fixture.contains("视频转码") }
        XCTAssertEqual(item.origin?.url.path, source.path)
        let visibleText = fixture.elements.filter { $0.accessibilityRole?() == .staticText }
            .map { element in
                String(describing: (element as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue())
            }.joined(separator: "\n")
        XCTAssertTrue(fixture.contains(source.deletingLastPathComponent().path),
                      "The default output folder must not be the disposable managed directory. Visible text:\n\(visibleText)")
        XCTAssertTrue(transcode.enqueue(directory: fixture.output, name: "result.mp4",
                                        managedMediaDirectory: fixture.model.managedImport.files.directory))
        try await wait { !transcode.queue.hasActiveJobs }
        let output = try XCTUnwrap(transcode.queue.jobs.first?.output)
        fixture.model.importTranscodedOutput(output)
        try await wait { !fixture.model.importing }
        try await fixture.settle()
        XCTAssertTrue(fixture.contains("已在素材库"))
        if fixture.contains("已在素材库") {
            XCTAssertEqual(try fixture.element("已在素材库", role: .button).isAccessibilityEnabled?(), false)
        }
        XCTAssertEqual(fixture.model.library.media.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        try await fixture.model.shutdownAndWait()
    }

    private func importImage(into fixture: SettingsPresentationFixture) async throws -> MediaItem {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = fixture.output.appendingPathComponent("source.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        fixture.model.importURLs([url])
        try await wait { !fixture.model.importing }
        XCTAssertNil(fixture.model.failure)
        return try XCTUnwrap(fixture.model.library.media.first)
    }

    private func requestClear(in fixture: SettingsPresentationFixture) async throws {
        _ = try fixture.element("备份并清空素材库…", role: .button).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet != nil }
    }

    private func button(_ title: String, in root: AnyObject) throws -> AnyObject {
        func descendants(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? []).flatMap { descendants($0 as AnyObject) }
        }
        return try XCTUnwrap(descendants(root).first {
            $0.accessibilityRole?() == .button && ($0.accessibilityLabel?() == title || $0.accessibilityTitle?() == title)
        }, "Missing confirmation button: \(title)")
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Managed media presentation timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
