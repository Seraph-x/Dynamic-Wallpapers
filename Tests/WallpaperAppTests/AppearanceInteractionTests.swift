import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class AppearanceInteractionTests: XCTestCase {
    func testEditingColorCodeUpdatesTheSavedAccent() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        try await fixture.selectTab("外观")
        let cell = try XCTUnwrap(fixture.element("颜色代码", role: .textField) as? NSTextFieldCell)
        let field = try XCTUnwrap(cell.controlView as? NSTextField)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("1", replacementRange: editor.selectedRange())
        XCTAssertEqual(field.stringValue, "#1")
        XCTAssertEqual(editor.selectedRange().location, 2)
        editor.insertText("2ABEF", replacementRange: editor.selectedRange())
        try await fixture.settle()

        let expected = AppAccentColor(red: 0x12, green: 0xAB, blue: 0xEF)
        XCTAssertEqual(fixture.model.library.settings.appearance.accentColor, expected)
        XCTAssertEqual(try fixture.model.store.load().settings.appearance.accentColor, expected)
        XCTAssertEqual(field.stringValue, expected.hexCode)

        editor.selectAll(nil)
        editor.insertText("00FF00", replacementRange: editor.selectedRange())
        try await fixture.settle()
        let pasted = AppAccentColor(red: 0, green: 255, blue: 0)
        XCTAssertEqual(field.stringValue, pasted.hexCode)
        XCTAssertEqual(fixture.model.library.settings.appearance.accentColor, pasted)
        XCTAssertEqual(try fixture.model.store.load().settings.appearance.accentColor, pasted)
    }

    func testAccentColorPersistsWithoutChangingOtherAppearanceSettings() throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let before = fixture.model.library.settings.appearance
        let expected = AppAccentColor(red: 0x12, green: 0xAB, blue: 0xEF)
        var changed = before
        changed.accentColor = expected

        XCTAssertTrue(fixture.model.setAppearance(changed))
        XCTAssertEqual(fixture.model.library.settings.appearance.accentColor, expected)
        XCTAssertEqual(try fixture.model.store.load().settings.appearance.accentColor, expected)
        XCTAssertEqual(changed.transparency, before.transparency)
        XCTAssertEqual(changed.blur, before.blur)
        XCTAssertEqual(changed.theme, before.theme)
        XCTAssertEqual(changed.fullScreenFrameRate, before.fullScreenFrameRate)
    }

    func testControlsPersistAndUpdateEveryOpenWindow() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let library = window(content: AnyView(LibraryView(
            model: fixture.model, product: ProductMetadataTestSupport.product)),
            size: NSSize(width: 1180, height: 760))
        let transcode = window(content: AnyView(TranscodeView(model: fixture.model)), size: NSSize(width: 780, height: 700))
        defer { library.contentView = nil; library.close(); transcode.contentView = nil; transcode.close() }
        XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 0.5)))
        let before = fixture.model.library
        try await fixture.show()
        try await fixture.selectTab("外观")

        let slider = try fixture.element("背景透明度", role: .slider)
        XCTAssertNotNil(slider.accessibilityPerformDecrement?())
        try await fixture.settle()
        let transparency = fixture.model.library.settings.appearance.transparency
        XCTAssertLessThan(transparency, 1)
        XCTAssertGreaterThan(transparency, 0)
        let windows = [library, fixture.window, transcode]
        var frostedSamples: [NSColor] = []
        for (index, window) in windows.enumerated() {
            frostedSamples.append(try await sampleBackground(in: window, fixture: fixture, name: "\(index)-frosted"))
        }
        fixture.window.makeKeyAndOrderFront(nil)
        XCTAssertNotNil(try fixture.element("清透", role: .radioButton).accessibilityPerformPress?())
        try await fixture.settle()
        let expected = AppAppearanceSettings(transparency: transparency, blur: .clear)
        XCTAssertEqual(fixture.model.library.settings.appearance, expected)
        XCTAssertEqual(try fixture.model.store.load().settings.appearance, expected)
        XCTAssertEqual(fixture.model.library.media, before.media)
        XCTAssertEqual(fixture.model.library.playlists, before.playlists)
        XCTAssertEqual(fixture.model.library.displays, before.displays)
        for (index, window) in windows.enumerated() {
            let clear = try await sampleBackground(in: window, fixture: fixture, name: "\(index)-clear")
            let frosted = frostedSamples[index]
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                let delta = max(abs(clear.redComponent - frosted.redComponent),
                    abs(clear.greenComponent - frosted.greenComponent), abs(clear.blueComponent - frosted.blueComponent))
                XCTAssertGreaterThan(delta, 0.02, "Each existing window must visibly switch to clear glass")
            }
            XCTAssertEqual(window.alphaValue, 1)
        }
        fixture.window.makeKeyAndOrderFront(nil)
        try await fixture.selectTab("关于")
        try await fixture.selectTab("外观")
        XCTAssertEqual(fixture.model.library.settings.appearance, expected)
        let restored = AppModel(store: fixture.model.store)
        XCTAssertFalse(restored.loadFailed)
        XCTAssertEqual(restored.library.settings.appearance, expected)
        try await restored.shutdownAndWait()
        try await fixture.model.shutdownAndWait()
    }

    func testFailedSaveKeepsPreviousAppearanceAndSuccessfulRetryClearsTheError() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        try await fixture.selectTab("外观")
        let before = fixture.model.library
        let unrelated = PresentedFailure(WallpaperError("原有的播放错误"), context: .playback)
        fixture.model.failure = unrelated
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try FileManager.default.createDirectory(at: fixture.model.store.url, withIntermediateDirectories: false)
        XCTAssertNotNil(try fixture.element("清透", role: .radioButton).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertEqual(fixture.model.library, before)
        let failure = try XCTUnwrap(fixture.model.appearanceFailure)
        XCTAssertTrue(fixture.contains(failure.summary), "Saving errors must be visible in the appearance page")
        XCTAssertEqual(fixture.model.failure, unrelated)
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try fixture.model.store.save(before)
        XCTAssertNotNil(try fixture.element("清透", role: .radioButton).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertEqual(fixture.model.library.settings.appearance.blur, .clear)
        XCTAssertEqual(try fixture.model.store.load().settings.appearance.blur, .clear)
        XCTAssertFalse(fixture.contains(failure.summary), "A successful retry must remove the obsolete saving error")
        XCTAssertNil(fixture.model.appearanceFailure)
        XCTAssertEqual(fixture.model.failure, unrelated, "Appearance recovery must not clear unrelated errors")
        try await fixture.model.shutdownAndWait()
    }

    func testInvalidTransparencyCannotReplaceTheSavedSettings() throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let before = fixture.model.library
        for value in [-0.01, 1.01, .infinity, .nan] {
            XCTAssertFalse(fixture.model.setAppearance(AppAppearanceSettings(transparency: value)))
            XCTAssertEqual(fixture.model.library, before)
            XCTAssertEqual(try fixture.model.store.load(), before)
            XCTAssertNotNil(fixture.model.appearanceFailure)
        }
    }

    private func window(content: AnyView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: (content).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderFront(nil)
        return window
    }

    private func sampleBackground(in window: NSWindow, fixture: SettingsPresentationFixture,
                                  name: String) async throws -> NSColor {
        window.makeKeyAndOrderFront(nil)
        try await fixture.settle()
        let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.animationBehavior = .none
        defer { backdrop.close() }
        backdrop.backgroundColor = .systemBlue
        backdrop.order(.below, relativeTo: window.windowNumber)
        try await fixture.settle()
        let image = try await WindowCompositorCapture.capture(window,
            to: fixture.output.appendingPathComponent("appearance-\(name).png"))
        let scale = CGFloat(image.pixelsWide) / window.frame.width
        // Empty lower-left window margin, outside form rows and foreground content.
        return try image.sRGBColor(atX: Int(30 * scale), y: image.pixelsHigh - Int(60 * scale))
    }
}
