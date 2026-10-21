import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class SheetGlassPresentationTests: XCTestCase {
    func testImporterHasNoNativeMaterialAsSoonAsItAttaches() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        try await fixture.show(appearance: .aqua)

        fixture.model.showingImport = true
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.window.attachedSheet == nil {
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("Importer did not attach")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let importer = try XCTUnwrap(fixture.window.attachedSheet)
        let frame = try XCTUnwrap(importer.contentView?.superview)
        let nativeMaterial = try XCTUnwrap(frame.subviews.compactMap { $0 as? NSVisualEffectView }
            .first { $0.material == .sheet })
        XCTAssertFalse(importer.isOpaque)
        XCTAssertEqual(importer.backgroundColor.alphaComponent, 0)
        XCTAssertTrue(nativeMaterial.isHidden, "The importer must be clear from its first attached frame")

        fixture.model.showingImport = false
        while fixture.window.attachedSheet != nil {
            guard ContinuousClock.now < deadline + .seconds(3) else {
                throw WallpaperError("Importer did not dismiss")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await fixture.model.shutdownAndWait()
    }

    func testBatchEditorAndImporterShareTheSavedGlassAppearance() async throws {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await assertPresentations(appearance: appearance, name: name)
        }
    }

    private func assertPresentations(appearance: NSAppearance.Name, name: String) async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let before = fixture.model.library
        try await fixture.show(appearance: appearance)
        XCTAssertEqual(try fixture.element(named: "批量选择", role: .button).accessibilityPerformPress?(), true)
        try await settle()
        XCTAssertEqual(try fixture.element(named: "全选当前结果", role: .button).accessibilityPerformPress?(), true)
        try await settle()
        XCTAssertEqual(try fixture.element(named: "批量编辑…", role: .button).accessibilityPerformPress?(), true)
        try await wait { fixture.window.attachedSheet != nil }
        let batch = try XCTUnwrap(fixture.window.attachedSheet)
        print("Batch presentation: parent=\(fixture.window.windowNumber), sheet=\(batch.windowNumber)")
        try await assertBackground(in: batch, fixture: fixture, name: "\(name)-batch",
                                   regions: [CGRect(x: 8, y: 60, width: 12, height: 24),
                                             CGRect(x: 60, y: 150, width: 40, height: 40)])
        XCTAssertEqual(try button("保存修改", in: batch).isAccessibilityEnabled?(), false)
        XCTAssertEqual(try button("取消", in: batch).accessibilityPerformPress?(), true)
        try await wait { fixture.window.attachedSheet == nil }

        fixture.model.showingImport = true
        try await wait { fixture.window.attachedSheet != nil }
        let importer = try XCTUnwrap(fixture.window.attachedSheet)
        try await assertBackground(in: importer, fixture: fixture, name: "\(name)-import",
                                   regions: [CGRect(x: 8, y: 60, width: 12, height: 24)])
        XCTAssertEqual(try button("选择文件…", in: importer).isAccessibilityEnabled?(), true)
        XCTAssertEqual(try button("取消", in: importer).accessibilityPerformPress?(), true)
        try await wait { fixture.window.attachedSheet == nil }
        XCTAssertFalse(fixture.model.showingImport)
        XCTAssertEqual(fixture.model.library.media, before.media)
        XCTAssertEqual(fixture.model.library.playlists, before.playlists)
        try await fixture.model.shutdownAndWait()
    }

    func testOpenHelpPopoverTracksAppearanceChanges() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        try await fixture.show(appearance: .aqua)
        XCTAssertEqual(try fixture.element(named: "过渡说明", role: .button).accessibilityPerformPress?(), true)
        let message = WallpaperCopy.transitionHelp
        try await wait { NSApp.windows.contains { $0.isVisible && self.contains(message, in: $0) } }
        let popover = try XCTUnwrap(NSApp.windows.first { $0.isVisible && self.contains(message, in: $0) })
        try await assertBackground(in: popover, fixture: fixture, name: "help",
                                   regions: [CGRect(x: 12, y: 8, width: 20, height: 4)])
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popover.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        popover.sendEvent(escape)
        try await wait { !popover.isVisible }
        try await fixture.model.shutdownAndWait()
    }

    private func assertBackground(in window: NSWindow, fixture: SelectionAppearanceFixture,
                                  name: String, regions: [CGRect]) async throws {
        let backdrop = NSWindow(contentRect: fixture.window.frame.union(window.frame).insetBy(dx: -20, dy: -20),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        defer { backdrop.close() }
        backdrop.order(.below, relativeTo: fixture.window.windowNumber)
        for (step, transparency) in [1.0, 0.65, 0.0, 1.0].enumerated() {
            XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: transparency)))
            var images: [NSBitmapImageRep] = []
            for (colorName, color) in [("red", NSColor.systemRed), ("blue", NSColor.systemBlue)] {
                backdrop.backgroundColor = color
                try await settle()
                images.append(try await WindowCompositorCapture.capture(window,
                    to: fixture.output.appendingPathComponent("\(name)-\(step)-\(transparency)-\(colorName).png")))
            }
            for region in regions {
                let delta = try difference(images[0], images[1], window: window, region: region)
                print("Presentation glass: \(name), transparency=\(transparency), region=\(region), delta=\(delta)")
                if transparency == 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                    XCTAssertLessThan(delta, 0.015, "The \(name) background must respect opaque appearance")
                } else {
                    XCTAssertGreaterThan(delta, 0.02, "The \(name) background must reveal the saved glass backdrop")
                }
            }
            XCTAssertEqual(window.alphaValue, 1, "Presentation text and controls must retain their opacity")
        }
    }

    private func difference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep,
                            window: NSWindow, region: CGRect) throws -> Double {
        let scale = CGFloat(first.pixelsWide) / window.frame.width
        let rect = CGRect(x: region.minX * scale, y: (window.frame.height - region.maxY) * scale,
                          width: region.width * scale, height: region.height * scale)
        var delta = 0.0
        var count = 0
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2) {
                let a = try first.sRGBColor(atX: x, y: y)
                let b = try second.sRGBColor(atX: x, y: y)
                delta += max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                             abs(a.blueComponent - b.blueComponent))
                count += 1
            }
        }
        return delta / Double(count)
    }

    private func button(_ title: String, in root: AnyObject) throws -> AnyObject {
        try XCTUnwrap(descendants(of: root).first {
            $0.accessibilityRole?() == .button && ($0.accessibilityTitle?() == title || $0.accessibilityLabel?() == title)
        }, "Missing presentation button: \(title)")
    }

    private func contains(_ text: String, in root: AnyObject) -> Bool {
        descendants(of: root).contains {
            $0.accessibilityRole?() == .staticText && ($0.accessibilityValue?() == text || $0.accessibilityLabel?() == text)
        }
    }

    private func descendants(of root: AnyObject) -> [AnyObject] {
        [root] + (root.accessibilityChildren?() ?? []).flatMap { descendants(of: $0 as AnyObject) }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Presentation did not reach the expected state") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle()
    }
}
