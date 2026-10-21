import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SystemWallpaperSettingsPresentationTests: XCTestCase {
    func testGeneralHasDefaultOffToggleWithoutExplanatoryCopy() async throws {
        let fixture = try SettingsPresentationFixture()
        addTeardownBlock { @MainActor in fixture.close(); try await fixture.model.shutdownAndWait() }
        try await fixture.show()
        XCTAssertTrue(fixture.contains("系统壁纸"))
        XCTAssertFalse(fixture.contains("同步正式壁纸的静态海报，预览不会修改系统底图。关闭、停止播放或退出后保留最后一张。"))
        let before: NSNumber? = try fixture.element("同步系统底图", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(try XCTUnwrap(before).boolValue, false)
        XCTAssertNotNil(try fixture.element("同步系统底图", role: .checkBox).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertTrue(fixture.model.systemWallpaperSync.enabled)
        XCTAssertTrue(try fixture.model.store.load().settings.systemWallpaperSyncEnabled)
        XCTAssertFalse(fixture.contains("应用壁纸后将同步对应显示器。"))
        XCTAssertTrue(fixture.contains("等待正式壁纸"))
        try await fixture.selectTab("高级")
        try await fixture.selectTab("通用")
        let after: NSNumber? = try fixture.element("同步系统底图", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(try XCTUnwrap(after).boolValue, true)
        try await fixture.model.shutdownAndWait()
    }

    func testSaveFailureIsShownWithoutFlippingTheRenderedSwitch() async throws {
        let fixture = try SettingsPresentationFixture()
        addTeardownBlock { @MainActor in fixture.close(); try await fixture.model.shutdownAndWait() }
        try await fixture.show()
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try FileManager.default.createDirectory(at: fixture.model.store.url, withIntermediateDirectories: false)
        XCTAssertNotNil(try fixture.element("同步系统底图", role: .checkBox).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertFalse(fixture.model.systemWallpaperSync.enabled)
        XCTAssertNotNil(fixture.model.systemWallpaperFailure)
        XCTAssertTrue(fixture.contains("保存失败。"))
        XCTAssertTrue(fixture.contains("错误详情"))
        let value: NSNumber? = try fixture.element("同步系统底图", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(try XCTUnwrap(value).boolValue, false)
        try await fixture.model.shutdownAndWait()
    }

    func testScreenFailureExposesDiagnosticsAndExplicitRetryReusesTheSavedPoster() async throws {
        var attempts: [URL] = []
        var fail = true
        let fixture = try SettingsPresentationFixture(setSystemDesktopImage: { url, _ in
            XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: url)))
            attempts.append(url)
            if fail { throw WallpaperError("系统底图同步失败。", diagnostic: "test-setter: denied 42") }
        })
        addTeardownBlock { @MainActor in fixture.close(); try await fixture.model.shutdownAndWait() }
        try await fixture.show()
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(screen.wallpaperID)
        let url = fixture.output.appendingPathComponent("formal-red.png")
        let bitmap = NSBitmapImageRep(cgImage: try SystemWallpaperFiles.image())
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let item = MediaItem(url: url, kind: .image, width: 8, height: 6)
        XCTAssertTrue(fixture.model.mutate { $0.media = [item] })
        fixture.model.applyMedia(item, displayID: displayID, fit: .fill)
        XCTAssertNotNil(try fixture.element("同步系统底图", role: .checkBox).accessibilityPerformPress?())
        try await waitForState(fixture.model, displayID: displayID) { if case .failed = $0 { return true }; return false }
        try await fixture.settle()
        XCTAssertEqual(attempts.count, 1)
        XCTAssertTrue(fixture.contains(screen.localizedName))
        XCTAssertTrue(fixture.contains("同步失败"))
        XCTAssertTrue(fixture.contains("错误详情"))
        guard case .failed(let failure) = fixture.model.systemWallpaperSync.states[displayID] else {
            return XCTFail("Missing screen failure")
        }
        XCTAssertEqual(failure.diagnostics, "test-setter: denied 42")
        fail = false
        XCTAssertNotNil(try fixture.element("重试同步", role: .button).accessibilityPerformPress?())
        try await waitForState(fixture.model, displayID: displayID) { if case .synced = $0 { return true }; return false }
        try await fixture.settle()
        XCTAssertTrue(fixture.contains("已同步"))
        XCTAssertFalse(fixture.contains("重试同步"))
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first, attempts.last)
        _ = try await fixture.capture("system-wallpaper-synced")
        try await fixture.model.shutdownAndWait()
    }

    private func waitForState(_ model: AppModel, displayID: String,
                              matching predicate: (SystemWallpaperSyncState?) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !predicate(model.systemWallpaperSync.states[displayID]) {
            if let failure = model.failure { throw failure }
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("System wallpaper setting did not reach expected state",
                                     diagnostic: String(describing: model.systemWallpaperSync.states))
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
