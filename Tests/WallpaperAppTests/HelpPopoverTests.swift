import AppKit
import SwiftUI
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class HelpPopoverTests: XCTestCase {
    func testHelpCanBeOpenedAndClosedWithKeyboard() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let message = "键盘可读的帮助说明。"
        let host = NSHostingView(rootView: (HelpPopover(title: "键盘", message: message).padding(50)).environment(\.locale, Locale(identifier: "zh-Hans")))
        fixture.window.contentView = host
        try await fixture.show(appearance: .aqua)
        XCTAssertTrue(fixture.window.makeFirstResponder(host))
        let button = try fixture.element(named: "键盘说明", role: .button)
        button.setAccessibilityFocused?(true)
        print("Help keyboard focus: fullKeyboardAccess=\(NSApp.isFullKeyboardAccessEnabled), focused=\(String(describing: button.isAccessibilityFocused?())), responder=\(String(describing: fixture.window.firstResponder))")
        XCTAssertEqual(button.isAccessibilityFocused?(), true)
        // Exercise the target window's responder chain, just like Escape below.
        // App-wide synthetic dispatch depends on state left by preceding UI tests.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            fixture.window.sendEvent(event)
        }
        try await wait { self.popover(containing: message) != nil }
        try escape(in: XCTUnwrap(popover(containing: message)))
        try await wait { self.popover(containing: message) == nil }
        try await fixture.model.shutdownAndWait()
    }

    func testNativeHoverHelpClickPopoverDynamicTextAndEscape() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let first = "保持画面比例，裁剪超出显示区域的部分。"
        let second = "显示完整画面，空余区域显示为黑色。"
        let host = NSHostingView(rootView: (HelpPopover(title: "显示方式", message: first).padding(50)).environment(\.locale, Locale(identifier: "zh-Hans")))
        fixture.window.contentView = host
        try await fixture.show(appearance: .aqua)
        let button = try fixture.element(named: "显示方式说明", role: .button)
        XCTAssertEqual(button.accessibilityHelp?(), first, "Native hover help must carry the original text")
        XCTAssertNil(popover(containing: first), "Help is absent from body before interaction")
        XCTAssertEqual(button.accessibilityPerformPress?(), true)
        try await wait { self.popover(containing: first) != nil }
        host.rootView = HelpPopover(title: "显示方式", message: second).padding(50)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
        try await wait { self.popover(containing: second) != nil }
        let popup = try XCTUnwrap(popover(containing: second))
        try escape(in: popup)
        try await wait { self.popover(containing: second) == nil }
        XCTAssertEqual(try fixture.element(named: "显示方式说明", role: .button).accessibilityPerformPress?(), true)
        try await wait { self.popover(containing: second) != nil }
        try escape(in: XCTUnwrap(popover(containing: second)))
        try await fixture.model.shutdownAndWait()
    }

    func testClosingHelpDoesNotStopTheWallpaperPreview() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let generated = try await VideoIntegrationTests.makeVideo()
        let source = fixture.output.appendingPathComponent("help-preview.mov")
        try FileManager.default.moveItem(at: generated, to: source)
        let item = try await MediaProbe.inspect(source)
        XCTAssertTrue(fixture.model.mutate { $0.media.append(item) })
        fixture.model.section = .library
        fixture.model.selectedMediaID = item.id
        try await fixture.show(appearance: .aqua)
        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).accessibilityPerformPress?(), true)
        try await wait { fixture.model.previewLifetime.activeSurfaceCount == 1 }
        let help = try fixture.element(named: "显示方式说明", role: .button)
        XCTAssertEqual(help.accessibilityPerformPress?(), true)
        let message = "保持画面比例，裁剪超出显示区域的部分。"
        try await wait { self.popover(containing: message) != nil }
        try escape(in: XCTUnwrap(popover(containing: message)))
        try await wait { self.popover(containing: message) == nil }
        _ = try fixture.element(named: "停止预览", role: .button)
        XCTAssertEqual(fixture.model.previewLifetime.activeSurfaceCount, 1)
        try await fixture.model.shutdownAndWait()
    }

    private func popover(containing text: String) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && containsStaticText(text, in: $0) }
    }

    private func containsStaticText(_ text: String, in root: AnyObject) -> Bool {
        if root.accessibilityRole?() == .staticText,
           root.accessibilityValue?() == text || root.accessibilityLabel?() == text { return true }
        return (root.accessibilityChildren?() ?? []).contains { containsStaticText(text, in: $0 as AnyObject) }
    }

    private func escape(in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(event)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Help popover interaction timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
