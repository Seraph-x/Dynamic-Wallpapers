import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class SettingsWindowInteractionTests: XCTestCase {
    func testSettingsSceneNavigationKeepsFocusAndSharesBackgroundAppearance() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Scene hosting requires macOS 26") }
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        // An opaque backing window supplies a real click-through recipient and
        // keeps compositor evidence independent of the user's desktop contents.
        fixture.window.contentView = NSView()
        fixture.window.backgroundColor = .windowBackgroundColor
        fixture.window.isOpaque = true
        fixture.window.title = ""
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        // Hosting SettingsView alone misses Settings scene toolbar promotion.
        let scene = NSHostingSceneRepresentation {
            WallpaperScenes(model: fixture.model, product: ProductMetadataTestSupport.product).settings }
        NSApp.addSceneRepresentation(scene)
        scene.environment.openSettings()
        try await fixture.settle()
        let window = try XCTUnwrap(NSApp.windows.first {
            !existing.contains(ObjectIdentifier($0)) && $0.isVisible && $0.canBecomeKey
        })
        defer { window.close() }
        fixture.window.setFrame(window.frame, display: true)
        fixture.window.order(.below, relativeTo: window.windowNumber)
        window.makeKeyAndOrderFront(nil)

        for language in [AppLanguage.english, .chinese] {
            XCTAssertTrue(fixture.model.setLanguage(language))
            for theme in [AppTheme.light, .dark] {
                for blur in GlassBlurStyle.allCases {
                    for transparency in [1.0, 0.5, 0.0] {
                        XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(
                            transparency: transparency, blur: blur, theme: theme)))
                        try await fixture.settle()
                        verifyWindowHitRegion(window)
                        let before = fixture.model.library
                        try await verifyTabs(in: window, fixture: fixture)
                        XCTAssertEqual(fixture.model.library, before, "Navigation must not change settings")
                        XCTAssertEqual(try fixture.model.store.load(), before)
                        if language == .english {
                            try await verifyBackground(in: window, fixture: fixture)
                        }
                        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
                        close.performClick(nil)
                        try await fixture.settle()
                        XCTAssertFalse(window.isVisible, "The native close button must close settings")
                        XCTAssertFalse(fixture.model.isShuttingDown, "Closing settings must keep the application running")
                        scene.environment.openSettings()
                        try await fixture.settle()
                        XCTAssertTrue(window.isKeyWindow, "Reopening must restore the same settings window")
                    }
                }
            }
        }
        try await fixture.model.shutdownAndWait()
    }

    private func verifyWindowHitRegion(_ window: NSWindow) {
        // Cover native close/minimize/zoom, title-bar gaps, page margins and content.
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), !button.isHidden else { continue }
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            XCTAssertEqual(NSWindow.windowNumber(at: NSPoint(x: frame.midX, y: frame.midY),
                belowWindowWithWindowNumber: 0), window.windowNumber, "Native window button must receive clicks: \(type)")
        }
        for x in [12.0, window.frame.width / 2, window.frame.width - 12] {
            // Stay above the native rounded bottom corners.
            for y in [40.0, window.frame.height / 2, window.frame.height - 12] {
                let point = NSPoint(x: window.frame.minX + x, y: window.frame.minY + y)
                XCTAssertEqual(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0),
                    window.windowNumber, "Settings must receive clicks across its complete surface: \(point)")
            }
        }
    }

    private func verifyTabs(in window: NSWindow, fixture: SettingsPresentationFixture) async throws {
        let tabs = navigationButtons(in: window)
        let titles = ["通用", "外观", "存储与素材", "高级", "关于"]
        XCTAssertEqual(tabs.count, titles.count)
        for (tab, title) in zip(tabs, titles) {
            let rect = try XCTUnwrap(tab.accessibilityFrame?())
            // AXPress bypasses WindowServer hit testing. Check the actual mouse-down
            // recipient throughout each button before exercising page selection.
            for x in [0.25, 0.5, 0.75] {
                for y in [0.25, 0.5, 0.75] {
                    let point = NSPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
                    XCTAssertEqual(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0),
                                   window.windowNumber, "Settings tab \(title) must receive clicks at \(point)")
                }
            }
            XCTAssertNotNil(tab.accessibilityPerformPress?())
            try await fixture.settle()
            XCTAssertEqual(tab.isAccessibilitySelected?(), true, "Tab must be selected: \(title)")
            XCTAssertTrue(window.isKeyWindow, "Selecting \(title) must keep focus in settings")
        }
    }

    private func verifyBackground(in window: NSWindow, fixture: SettingsPresentationFixture) async throws {
        let tab = try XCTUnwrap(navigationButtons(in: window).first)
        let tabFrame = try XCTUnwrap(tab.accessibilityFrame?())
        let appearance = fixture.model.library.settings.appearance
        let name = "\(appearance.theme)-\(appearance.blur)-\(appearance.transparency)"
        var samples: [NSColor] = []
        for (colorName, color) in [("red", NSColor.systemRed), ("blue", NSColor.systemBlue)] {
            fixture.window.backgroundColor = color
            try await fixture.settle()
            let image = try await WindowCompositorCapture.capture(window, to: fixture.output
                .appendingPathComponent("settings-navigation-\(name)-\(colorName).png"))
            let scale = CGFloat(image.pixelsWide) / window.frame.width
            let header = try image.sRGBColor(atX: Int(12 * scale),
                y: Int((window.frame.maxY - tabFrame.midY) * scale))
            let body = try image.sRGBColor(atX: Int(12 * scale), y: image.pixelsHigh - Int(50 * scale))
            XCTAssertLessThan(distance(header, body), 0.04,
                              "Navigation and page background must match: \(name), \(colorName)")
            for button in navigationButtons(in: window) {
                let frame = try XCTUnwrap(button.accessibilityFrame?())
                let buttonBackground = try image.sRGBColor(
                    atX: Int((frame.midX - window.frame.minX) * scale),
                    y: Int((window.frame.maxY - frame.minY - 3) * scale))
                XCTAssertLessThan(distance(buttonBackground, header), 0.02,
                                  "Selected and unselected tabs must have no visible fill: \(name), \(colorName)")
            }
            samples.append(header)
        }
        let delta = distance(samples[0], samples[1])
        if appearance.transparency == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            XCTAssertLessThan(delta, 0.01, "Opaque navigation must hide the backdrop")
        } else {
            XCTAssertGreaterThan(delta, 0.02, "Navigation must follow the saved transparency: \(name)")
        }
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> Double {
        max(abs(first.redComponent - second.redComponent), abs(first.greenComponent - second.greenComponent),
            abs(first.blueComponent - second.blueComponent))
    }

    private func descendants(_ element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).flatMap { descendants($0 as AnyObject) }
    }

    private func navigationButtons(in window: NSWindow) -> [AnyObject] {
        descendants(window).filter {
            $0.accessibilityRole?() == .button &&
            ($0.accessibilityIdentifier?() ?? "").hasPrefix("settings-tab-")
        }
    }
}
