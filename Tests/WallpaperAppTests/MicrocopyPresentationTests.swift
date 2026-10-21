import AppKit
import SwiftUI
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class MicrocopyPresentationTests: XCTestCase {
    func testUnappliedWallpaperUsesAStatusRatherThanASlogan() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        XCTAssertEqual(fixture.model.playbackSummary, "尚未应用壁纸")
        try await fixture.model.shutdownAndWait()
    }

    func testPlaylistExplanationsAreHelpAndControlsHaveNames() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        try await fixture.show(appearance: .aqua)
        try await fixture.waitForPlaylistControls()
        let help = try fixture.element(named: "过渡说明", role: .button)
        XCTAssertEqual(help.accessibilityHelp?(), "画面与声音同步渐变。")
        XCTAssertFalse(contains("画面与声音同步渐变。", in: fixture.window))
        for name in ["上移", "下移"] {
            _ = try fixture.element(named: name, role: .button)
        }
        XCTAssertFalse(contains("暂停播放", in: fixture.window))
        XCTAssertFalse(contains("下一张壁纸", in: fixture.window))
        try await fixture.model.shutdownAndWait()
    }

    func testDisplayConfigurationHasNoSlogan() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.model.section = .displays
        try await fixture.show(appearance: .aqua)
        XCTAssertFalse(contains("每一块屏幕，都有自己的风景", in: fixture.window))
        XCTAssertFalse(contains("从素材库应用单张壁纸，也可以在这里选择播放列表。", in: fixture.window))
        try await fixture.model.shutdownAndWait()
    }

    func testDirectTransitionHelpDoesNotPromiseAGradient() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        var playlist = try XCTUnwrap(fixture.model.selectedPlaylist)
        playlist.transition = 0
        fixture.model.updatePlaylist(playlist)
        try await fixture.show(appearance: .aqua)
        try await fixture.waitForPlaylistControls()
        XCTAssertEqual(try fixture.element(named: "过渡说明", role: .button).accessibilityHelp?(), "画面与声音直接切换。")
        try await fixture.model.shutdownAndWait()
    }

    func testWebEntryLabelRemainsVisibleWhenTheFieldHasAValue() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.window.contentView = NSHostingView(rootView: (WallpaperImportView(model: fixture.model, projectRoot: fixture.output)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        XCTAssertTrue(contains("入口文件（HTML）", in: fixture.window))
        _ = try fixture.element(named: "选择入口文件…", role: .button)
        _ = try fixture.element(named: "导入网页项目", role: .button)
        try await fixture.model.shutdownAndWait()
    }

    func testMenuErrorPresentationDoesNotClearALaterFailure() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try FileManager.default.createDirectory(at: fixture.model.store.url, withIntermediateDirectories: false)
        var shown: PresentedFailure?
        fixture.window.contentView = NSHostingView(rootView: (GlobalMuteToggle(model: fixture.model, showMenuError: true) { failure in
            shown = failure
            XCTAssertNil(fixture.model.failure, "The menu owns this error before entering the modal event loop")
            fixture.model.report(WallpaperError("A later playback failure"))
        }.padding(30)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        _ = try fixture.element(named: "全局静音", role: .checkBox).accessibilityPerformPress?()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(shown?.title, "无法保存全局静音设置")
        XCTAssertEqual(fixture.model.errorMessage, "A later playback failure")
        try await fixture.model.shutdownAndWait()
    }

    private func contains(_ text: String, in root: AnyObject) -> Bool {
        let value = root.accessibilityRole?() == .staticText ? accessibilityText("accessibilityValue", of: root) : nil
        if accessibilityText("accessibilityLabel", of: root) == text
            || accessibilityText("accessibilityTitle", of: root) == text || value == text { return true }
        return (root.accessibilityChildren?() ?? []).contains { contains(text, in: $0 as AnyObject) }
    }

    private func accessibilityText(_ name: String, of element: AnyObject) -> String? {
        // macOS 27 can return NSAttributedString despite the String-typed AX declaration.
        let selector = NSSelectorFromString(name)
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        let value = object.perform(selector)?.takeUnretainedValue()
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }

}
