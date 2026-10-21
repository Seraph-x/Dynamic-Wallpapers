@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class UnifiedPreviewPresentationTests: XCTestCase {
    func testExistingPowerPauseDisablesPreviewButManualPauseDoesNot() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.model.section = .library
        fixture.model.selectedMediaID = fixture.model.library.media[0].id
        try await fixture.show(appearance: .aqua)
        try await wait { !fixture.model.inspectorMedia.isChecking }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await wait { fixture.model.pauseReasons.contains("系统休眠") }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).isAccessibilityEnabled?(), false)
        fixture.model.togglePause()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await wait { fixture.model.pauseReasons.isEmpty }
        XCTAssertTrue(fixture.model.userPaused)
        try await startImagePreview(fixture)
        try await fixture.model.shutdownAndWait()
    }

    func testImageUsesSameButtonAndClosingAnotherWindowDoesNotStopPreview() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        try await startImagePreview(fixture)
        let auxiliary = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 100, height: 100),
                                 styleMask: .titled, backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false
        auxiliary.orderBack(nil)
        auxiliary.close()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(fixture.model.previewLifetime.activeDesktopSurfaceCount, 0)
        XCTAssertTrue(hasButton("停止预览", in: fixture.window))
        fixture.window.close()
        try await wait { fixture.model.previewLifetime.activeSurfaceCount == 0 }
        XCTAssertTrue(visibleDesktopWindows.isEmpty)
        try await fixture.model.shutdownAndWait()
    }

    func testApplyingPreviewKeepsNewBindingAndEndsBothTemporaryCopies() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let original = fixture.model.library.media[0]
        let candidate = fixture.model.library.media[1]
        fixture.model.applyMedia(original, displayID: nil, fit: .fill)
        try await wait { fixture.model.statuses.values.contains { $0.hasPrefix("正在播放") } }
        try await startImagePreview(fixture, item: candidate)
        XCTAssertEqual(try fixture.element(named: "应用壁纸", role: .button).accessibilityPerformPress?(), true)
        try await wait { fixture.model.previewLifetime.activeSurfaceCount == 0 }
        XCTAssertTrue(fixture.model.library.displays.allSatisfy { $0.source.mediaID == candidate.id })
        XCTAssertEqual(try fixture.model.store.load(), fixture.model.library)
        try await wait { fixture.model.statuses.values.contains { $0.hasPrefix("正在播放") } }
        XCTAssertEqual(visibleDesktopWindows.count, NSScreen.screens.count)
        XCTAssertTrue(hasButton("播放预览", in: fixture.window))
        try await fixture.model.shutdownAndWait()
    }

    func testFailedApplicationSaveKeepsPreviewAndOriginalBinding() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        try await startImagePreview(fixture)
        let original = fixture.model.library
        let saved = fixture.model.store.url
        let backup = fixture.output.appendingPathComponent("preview-save-backup.json")
        try FileManager.default.moveItem(at: saved, to: backup)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        XCTAssertEqual(try fixture.element(named: "应用壁纸", role: .button).accessibilityPerformPress?(), true)
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertNotNil(fixture.model.failure)
        XCTAssertGreaterThan(fixture.model.previewLifetime.activeDesktopSurfaceCount, 0)
        try FileManager.default.removeItem(at: saved)
        try FileManager.default.moveItem(at: backup, to: saved)
        try await fixture.model.shutdownAndWait()
    }

    func testSleepEndsPreviewAndResetsTheSharedButton() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        try await startImagePreview(fixture)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await wait {
            fixture.model.previewLifetime.activeSurfaceCount == 0 && self.hasButton("播放预览", in: fixture.window)
        }
        XCTAssertTrue(visibleDesktopWindows.isEmpty)
        XCTAssertTrue(fixture.model.pauseReasons.contains("系统休眠"))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await fixture.model.shutdownAndWait()
    }

    func testExistingPreviewButtonPlaysInlineAndOnDesktopWithoutSavingBindings() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let generated = try await VideoIntegrationTests.makeVideo()
        let url = fixture.output.appendingPathComponent("Unified.mov")
        try FileManager.default.moveItem(at: generated, to: url)
        let item = try await MediaProbe.inspect(url)
        XCTAssertTrue(fixture.model.mutate { $0.media.append(item) })
        fixture.model.section = .library
        fixture.model.selectedMediaID = item.id
        try await fixture.show(appearance: .aqua)
        try await wait { !fixture.model.inspectorMedia.isChecking }
        let saved = try Data(contentsOf: fixture.model.store.url)

        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).accessibilityPerformPress?(), true)
        try await wait { self.inlineSurface(in: fixture.window.contentView)?.isPlaying == true }
        XCTAssertEqual(visibleDesktopWindows.count, NSScreen.screens.count,
                       "The existing preview button must also take over the selected desktops")
        XCTAssertEqual(try Data(contentsOf: fixture.model.store.url), saved)
        XCTAssertTrue(fixture.model.library.displays.isEmpty)
        XCTAssertFalse(hasButton("桌面预览", in: fixture.window), "Do not add a separate desktop-preview entry point")

        XCTAssertEqual(try fixture.element(named: "停止预览", role: .button).accessibilityPerformPress?(), true)
        try await wait { fixture.model.previewLifetime.activeSurfaceCount == 0 }
        XCTAssertTrue(visibleDesktopWindows.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.model.store.url), saved)
        try await fixture.model.shutdownAndWait()
    }

    private var visibleDesktopWindows: [DesktopWindow] {
        NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }.filter(\.hasVisibleWallpaper)
    }

    private func startImagePreview(_ fixture: SelectionAppearanceFixture, item: MediaItem? = nil) async throws {
        fixture.model.section = .library
        fixture.model.selectedMediaID = item?.id ?? fixture.model.library.media[0].id
        try await fixture.show(appearance: .aqua)
        try await wait { !fixture.model.inspectorMedia.isChecking }
        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).accessibilityPerformPress?(), true)
        try await wait { self.inlineSurface(in: fixture.window.contentView)?.isPlaying == true }
        XCTAssertGreaterThan(fixture.model.previewLifetime.activeDesktopSurfaceCount, 0)
    }

    private func inlineSurface(in view: NSView?) -> MediaSurface? {
        guard let view else { return nil }
        if let surface = view as? MediaSurface { return surface }
        return view.subviews.lazy.compactMap { self.inlineSurface(in: $0) }.first
    }

    private func hasButton(_ title: String, in root: AnyObject) -> Bool {
        if root.accessibilityRole?() == .button,
           root.accessibilityLabel?() == title || root.accessibilityTitle?() == title { return true }
        return (root.accessibilityChildren?() ?? []).contains { hasButton(title, in: $0 as AnyObject) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Unified preview UI timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
