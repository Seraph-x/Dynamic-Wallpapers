import AppKit
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WallpaperFrameRateSettingsTests: XCTestCase {
    func testWebWallpaperFrameRatePersistsEveryUserChoice() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        try await fixture.selectTab("外观")
        XCTAssertTrue(fixture.contains("网页壁纸帧率"))
        XCTAssertEqual(fixture.model.library.settings.webWallpaperFrameRate, .fps30)
        for rate in [WebWallpaperFrameRate.fps24, .fps60, .fps30] {
            let control = try fixture.element("\(rate.rawValue) FPS", role: .radioButton)
            XCTAssertNotNil(control.accessibilityPerformPress?())
            try await fixture.settle()
            XCTAssertEqual(fixture.model.library.settings.webWallpaperFrameRate, rate)
            XCTAssertEqual(try fixture.model.store.load().settings.webWallpaperFrameRate, rate)
            XCTAssertEqual(fixture.model.webRuntime.frameRate, rate)
        }
        try await fixture.model.shutdownAndWait()
    }

    func testFrameRateControlsPersistBothChoicesAndRestoreThem() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let before = fixture.model.library
        try await fixture.show()
        try await fixture.selectTab("外观")
        XCTAssertTrue(fixture.contains("全屏背景帧率"))
        XCTAssertEqual(fixture.model.library.settings.appearance.fullScreenFrameRate, .hz30)
        for rate in [WallpaperMirrorFrameRate.hz60, .hz30] {
            let control = try fixture.element("\(rate.rawValue) Hz", role: .radioButton)
            XCTAssertNotNil(control.accessibilityPerformPress?())
            try await fixture.settle()
            let selected: NSNumber? = control.accessibilityValue?()
            XCTAssertEqual(try XCTUnwrap(selected).boolValue, true)
            XCTAssertEqual(fixture.model.library.settings.appearance.fullScreenFrameRate, rate)
            XCTAssertEqual(try fixture.model.store.load().settings.appearance.fullScreenFrameRate, rate)
            let restored = AppModel(store: fixture.model.store)
            XCTAssertFalse(restored.loadFailed)
            XCTAssertEqual(restored.library.settings.appearance.fullScreenFrameRate, rate)
            try await restored.shutdownAndWait()
        }
        XCTAssertEqual(fixture.model.library.media, before.media)
        XCTAssertEqual(fixture.model.library.playlists, before.playlists)
        XCTAssertEqual(fixture.model.library.displays, before.displays)
        XCTAssertEqual(fixture.model.library.settings.appearance.transparency, before.settings.appearance.transparency)
        XCTAssertEqual(fixture.model.library.settings.appearance.blur, before.settings.appearance.blur)
        _ = try await fixture.capture("frame-rate-settings")
        try await fixture.model.shutdownAndWait()
    }

    func testFrameRateSaveFailureKeepsPreviousSelectionAndShowsError() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        try await fixture.selectTab("外观")
        let before = fixture.model.library
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try FileManager.default.createDirectory(at: fixture.model.store.url, withIntermediateDirectories: false)
        XCTAssertNotNil(try fixture.element("60 Hz", role: .radioButton).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertEqual(fixture.model.library, before)
        let failure = try XCTUnwrap(fixture.model.appearanceFailure)
        XCTAssertTrue(fixture.contains(failure.summary))
        let selected: NSNumber? = try fixture.element("30 Hz", role: .radioButton).accessibilityValue?()
        XCTAssertEqual(try XCTUnwrap(selected).boolValue, true)
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try fixture.model.store.save(before)
        XCTAssertNotNil(try fixture.element("60 Hz", role: .radioButton).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertEqual(fixture.model.library.settings.appearance.fullScreenFrameRate, .hz60)
        XCTAssertEqual(try fixture.model.store.load().settings.appearance.fullScreenFrameRate, .hz60)
        XCTAssertNil(fixture.model.appearanceFailure)
        try await fixture.model.shutdownAndWait()
    }

    func testSettingsRenderAfterAnEarlierAppKitEventPump() async throws {
        _ = NSApplication.shared
        let earlierWindow = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 200, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        earlierWindow.isReleasedWhenClosed = false
        defer { earlierWindow.close() }
        var pumped = false
        try await WallpaperMirrorTestSupport.waitUntil(description: "Event pump before settings initialization") {
            defer { pumped = true }
            return pumped
        }
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        try await fixture.selectTab("外观")
        XCTAssertTrue(fixture.contains("全屏背景帧率"))
        try await fixture.model.shutdownAndWait()
    }
}
