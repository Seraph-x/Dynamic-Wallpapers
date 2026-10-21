import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class PureTransparencyTests: XCTestCase {
    func testMaximumTransparencyPreservesSharpBackdropInEveryWindow() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                      "Pure transparency is disabled by the system's accessibility preference")
        let roots: [(String, String, NSSize, (AppModel) -> AnyView)] = [
            ("library", "导入壁纸", NSSize(width: 1180, height: 760), {
                AnyView(LibraryView(model: $0, product: ProductMetadataTestSupport.product)) }),
            ("settings", "外观", SettingsView.minimumSize, {
                AnyView(SettingsView(model: $0, product: ProductMetadataTestSupport.product)) }),
            ("transcode", "视频转码", NSSize(width: 780, height: 700), { AnyView(TranscodeView(model: $0)) })
        ]
        for (name, readyText, size, content) in roots {
            let fixture = try SettingsPresentationFixture(content: content)
            defer { fixture.close() }
            fixture.window.setContentSize(size)
            try await fixture.show(readyText: readyText)
            // SwiftUI enforces the settings minimum size; position its final frame onscreen.
            fixture.window.center()
            try await fixture.settle()
            // The general form now reaches the bottom. Sample its empty left margin,
            // not foreground labels, when measuring background transparency.
            let region = name == "settings" ? CGRect(x: 10, y: 40, width: 30, height: 50)
                : CGRect(x: 30, y: 40, width: 60, height: 50)
            let backdrop = makeBackdrop(for: fixture.window)
            let focus = NSWindow(contentRect: CGRect(x: 10, y: 10, width: 50, height: 30),
                                 styleMask: .titled, backing: .buffered, defer: false)
            focus.isReleasedWhenClosed = false
            defer { backdrop.close(); focus.close() }
            backdrop.contentView = CheckerboardBackdrop(frame: CGRect(origin: .zero, size: backdrop.frame.size))
            backdrop.order(.above, relativeTo: fixture.window.windowNumber)
            try await fixture.settle()
            let reference = try await capture(fixture, name: "\(name)-reference")
            backdrop.order(.below, relativeTo: fixture.window.windowNumber)

            for style in GlassBlurStyle.allCases {
                for transparency in [0.5, 1.0] {
                    XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(
                        transparency: transparency, blur: style)))
                    try await fixture.settle()
                    let rendered = try await capture(fixture, name: "\(name)-\(style)-\(transparency)")
                    let error = try backgroundDifference(reference, rendered, window: fixture.window, region: region)
                    print("Backdrop detail: \(name), \(style), transparency=\(transparency), error=\(error)")
                    if transparency == 1 {
                        XCTAssertLessThan(error, 0.015, "\(name) must preserve sharp background pixels at 100%")
                        XCTAssertFalse(fixture.window.isOpaque)
                        let expectedBackingAlpha = name == "transcode" ? 0 : 1.0 / 255
                        XCTAssertEqual(fixture.window.backgroundColor.alphaComponent, expectedBackingAlpha,
                                       accuracy: 0.0001,
                                       "Click-receiving library and settings windows must keep their invisible mouse-hit backing")
                    } else {
                        XCTAssertGreaterThan(error, 0.1, "Glass must return when transparency is reduced")
                    }
                    XCTAssertEqual(fixture.window.alphaValue, 1, "Foreground content must remain fully opaque")
                }
                focus.makeKeyAndOrderFront(nil)
                try await fixture.settle()
                XCTAssertFalse(fixture.window.isKeyWindow)
                let inactive = try await capture(fixture, name: "\(name)-\(style)-inactive")
                XCTAssertLessThan(try backgroundDifference(reference, inactive, window: fixture.window, region: region), 0.015,
                                  "Pure transparency must survive loss of focus")
                fixture.window.makeKeyAndOrderFront(nil)
            }
            try await fixture.model.shutdownAndWait()
        }
    }

    func testReduceTransparencyKeepsMaximumSettingOpaque() async throws {
        let fixture = try SettingsPresentationFixture { model in
            AnyView(WindowGlassBackground(appearance: model.library.settings.appearance, reducesTransparency: true))
        }
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 1)))
        try await fixture.showWindow()
        let backdrop = makeBackdrop(for: fixture.window)
        defer { backdrop.close() }
        backdrop.order(.below, relativeTo: fixture.window.windowNumber)
        var captures: [NSBitmapImageRep] = []
        for (name, color) in [("red", NSColor.systemRed), ("blue", NSColor.systemBlue)] {
            backdrop.backgroundColor = color
            try await fixture.settle()
            captures.append(try await capture(fixture, name: "reduced-transparency-\(name)"))
        }
        XCTAssertLessThan(try backgroundDifference(captures[0], captures[1], window: fixture.window), 0.01,
                          "The system's Reduce Transparency preference must keep the background opaque")
        XCTAssertEqual(fixture.model.library.settings.appearance.transparency, 1,
                       "Accessibility must not overwrite the user's saved preference")
        try await fixture.model.shutdownAndWait()
    }

    func testPlaylistBackgroundPreservesSharpBackdrop() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                      "Pure transparency is disabled by the system's accessibility preference")
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 1)))
        let backdrop = makeBackdrop(for: fixture.window)
        defer { backdrop.close() }
        backdrop.contentView = CheckerboardBackdrop(frame: CGRect(origin: .zero, size: backdrop.frame.size))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await fixture.show(appearance: appearance)
            let scroll = try XCTUnwrap(fixture.tables.last?.enclosingScrollView)
            let frame = scroll.convert(scroll.bounds, to: nil)
            let region = CGRect(x: frame.minX + 20, y: frame.minY + 20, width: 80, height: 50)
            backdrop.order(.above, relativeTo: fixture.window.windowNumber)
            try await Task.sleep(for: .milliseconds(150))
            let reference = try await fixture.capture("\(name)-pure-playlist-reference")
            backdrop.order(.below, relativeTo: fixture.window.windowNumber)
            try await Task.sleep(for: .milliseconds(150))
            let rendered = try await fixture.capture("\(name)-pure-playlist")
            let error = try backgroundDifference(reference, rendered, window: fixture.window, region: region)
            print("Playlist background detail: \(name), error=\(error)")
            XCTAssertLessThan(error, 0.015, "A populated playlist must not add an opaque scroll background")
        }
        try await fixture.model.shutdownAndWait()
    }

    private func makeBackdrop(for window: NSWindow) -> NSWindow {
        let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        // A reference captured during AppKit's order-front animation has resampled gray edges.
        // Disable animation only for the test backdrop, not the window whose glass is exercised.
        backdrop.animationBehavior = .none
        return backdrop
    }

    private func capture(_ fixture: SettingsPresentationFixture, name: String) async throws -> NSBitmapImageRep {
        try await WindowCompositorCapture.capture(fixture.window,
            to: fixture.output.appendingPathComponent("\(name).png"))
    }

    private func backgroundDifference(_ reference: NSBitmapImageRep, _ rendered: NSBitmapImageRep,
                                      window: NSWindow,
                                      region: CGRect = CGRect(x: 30, y: 40, width: 60, height: 50)) throws -> Double {
        XCTAssertEqual(reference.pixelsWide, rendered.pixelsWide)
        XCTAssertEqual(reference.pixelsHigh, rendered.pixelsHigh)
        let scale = CGFloat(rendered.pixelsWide) / window.frame.width
        let rect = CGRect(x: region.minX * scale, y: (window.frame.height - region.maxY) * scale,
                          width: region.width * scale, height: region.height * scale)
        var difference = 0.0
        var count = 0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 3) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 3) {
                let expected = try reference.sRGBColor(atX: x, y: y)
                let actual = try rendered.sRGBColor(atX: x, y: y)
                difference += max(abs(expected.redComponent - actual.redComponent),
                                  abs(expected.greenComponent - actual.greenComponent),
                                  abs(expected.blueComponent - actual.blueComponent))
                count += 1
            }
        }
        return difference / Double(count)
    }
}

private final class CheckerboardBackdrop: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let tileSize = 8
        for y in stride(from: 0, to: Int(bounds.height), by: tileSize) {
            for x in stride(from: 0, to: Int(bounds.width), by: tileSize) {
                let white = (x / tileSize + y / tileSize).isMultiple(of: 2)
                (white ? NSColor.white : NSColor.black).setFill()
                NSRect(x: x, y: y, width: tileSize, height: tileSize).fill()
            }
        }
    }
}
