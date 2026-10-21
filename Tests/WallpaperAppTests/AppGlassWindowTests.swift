import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class AppGlassWindowTests: XCTestCase {
    func testEveryWindowUsesTheSavedBackgroundTransparency() async throws {
        let roots: [(String, String, NSSize, (AppModel) -> AnyView)] = [
            ("library", "导入壁纸", NSSize(width: 1180, height: 760), {
                AnyView(LibraryView(model: $0, product: ProductMetadataTestSupport.product)) }),
            ("settings", "外观", NSSize(width: 560, height: 460), {
                AnyView(SettingsView(model: $0, product: ProductMetadataTestSupport.product)) }),
            ("transcode", "视频转码", NSSize(width: 780, height: 700), { AnyView(TranscodeView(model: $0)) })
        ]
        for (name, readyText, size, content) in roots {
            let fixture = try SettingsPresentationFixture(content: content)
            defer { fixture.close() }
            fixture.window.setContentSize(size)
            try await fixture.show(readyText: readyText)
            let backdrop = NSWindow(contentRect: fixture.window.frame.insetBy(dx: -20, dy: -20),
                                    styleMask: .borderless, backing: .buffered, defer: false)
            backdrop.isReleasedWhenClosed = false
            defer { backdrop.close() }
            backdrop.order(.below, relativeTo: fixture.window.windowNumber)
            var deltas: [Double] = []
            for transparency in [1.0, 0.5, 0.0] {
                XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: transparency)))
                var samples: [NSColor] = []
                for (colorName, color) in [("red", NSColor.systemRed), ("blue", NSColor.systemBlue)] {
                    backdrop.backgroundColor = color
                    try await fixture.settle()
                    let url = fixture.output.appendingPathComponent("\(name)-\(transparency)-\(colorName).png")
                    let image = try await WindowCompositorCapture.capture(fixture.window, to: url)
                    samples.append(try sampleBackground(image, window: fixture.window))
                }
                let delta = distance(samples[0], samples[1])
                deltas.append(delta)
                print("Window glass: \(name), transparency=\(transparency), backdropDelta=\(delta)")
                XCTAssertEqual(fixture.window.alphaValue, 1, "The window's text and controls must retain full opacity")
                if transparency == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                    XCTAssertLessThan(delta, 0.01, "\(name) must have an opaque background")
                } else {
                    XCTAssertGreaterThan(delta, 0.02, "\(name) must reveal colors behind the window")
                }
            }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                XCTAssertGreaterThan(deltas[0], deltas[1] + 0.01, "The \(name) slider must change the rendered background")
            }
            try await fixture.model.shutdownAndWait()
        }
    }

    func testClearAndFrostedRemainDistinctWhenTheWindowIsInactive() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let backdrop = NSWindow(contentRect: fixture.window.frame.insetBy(dx: -20, dy: -20),
                                styleMask: .borderless, backing: .buffered, defer: false)
        let focus = NSWindow(contentRect: CGRect(x: 10, y: 10, width: 160, height: 60),
                             styleMask: [.titled], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        focus.isReleasedWhenClosed = false
        defer { backdrop.close(); focus.close() }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await fixture.show(appearance: appearance)
            backdrop.order(.below, relativeTo: fixture.window.windowNumber)
            // SwiftUI can resize the settings window on presentation; use its final frame.
            focus.setFrameOrigin(NSPoint(x: fixture.window.frame.maxX + 20, y: fixture.window.frame.minY))
            focus.makeKeyAndOrderFront(nil)
            var blueSamples: [NSColor] = []
            var backdropDeltas: [Double] = []
            for style in GlassBlurStyle.allCases {
                XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 0.5, blur: style)))
                var samples: [NSColor] = []
                for (colorName, color) in [("red", NSColor.systemRed), ("blue", NSColor.systemBlue)] {
                    backdrop.backgroundColor = color
                    try await fixture.settle()
                    XCTAssertFalse(fixture.window.isKeyWindow)
                    XCTAssertTrue(focus.isKeyWindow)
                    XCTAssertTrue(try XCTUnwrap(fixture.window.screen).frame.contains(focus.frame),
                                  "The focus helper must remain onscreen")
                    XCTAssertFalse(focus.frame.intersects(fixture.window.frame),
                                   "The focus helper must not obscure the window whose glass is being sampled")
                    let url = fixture.output.appendingPathComponent("\(name)-\(style.rawValue)-inactive-\(colorName).png")
                    samples.append(try sampleBackground(await WindowCompositorCapture.capture(fixture.window, to: url),
                                                        window: fixture.window))
                }
                blueSamples.append(samples[1])
                backdropDeltas.append(distance(samples[0], samples[1]))
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                    XCTAssertGreaterThan(distance(samples[0], samples[1]), 0.02, "\(style) must retain its inactive glass")
                }
            }
            let delta = distance(blueSamples[0], blueSamples[1])
            print("Native glass style difference: \(name), delta=\(delta)")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                XCTAssertGreaterThan(delta, 0.02, "Clear and frosted must have visibly different native materials")
                if #available(macOS 26, *) {
                    XCTAssertGreaterThan(backdropDeltas[0], backdropDeltas[1] + 0.02,
                        "Clear glass must reveal more backdrop color than frosted glass in \(name) appearance")
                }
            }
        }
        try await fixture.model.shutdownAndWait()
    }

    private func sampleBackground(_ image: NSBitmapImageRep, window: NSWindow) throws -> NSColor {
        let scale = CGFloat(image.pixelsWide) / window.frame.width
        let rect = CGRect(x: 30 * scale, y: (window.frame.height - 90) * scale, width: 60 * scale, height: 60 * scale)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 4) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 4) {
                let color = try image.sRGBColor(atX: x, y: y)
                red += color.redComponent; green += color.greenComponent; blue += color.blueComponent
                count += 1
            }
        }
        return NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1)
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> Double {
        max(abs(first.redComponent - second.redComponent), abs(first.greenComponent - second.greenComponent),
            abs(first.blueComponent - second.blueComponent))
    }
}
