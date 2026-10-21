import AppKit
import SwiftUI
import XCTest
@testable import WallpaperApp

@MainActor
final class AppBrandingTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testDisplayNameAndIdentityComeFromInjectedProductMetadata() throws {
        let info = try ProductMetadataTestSupport.information()
        let product = ProductMetadataTestSupport.product
        XCTAssertEqual(info["CFBundleName"] as? String, product.displayName)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, product.displayName)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, product.executable)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, product.applicationBundleIdentifier)
    }

    func testMenuBarIconIsATransparentResolutionIndependentTemplate() throws {
        let icon = AppBranding.menuBarIcon
        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertNil(icon.accessibilityDescription)
        let output = root.appendingPathComponent(".build/verification/branding")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scale in [1, 2, 10] {
            let bitmap = try renderIcon(scale: scale)
            let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
            XCTAssertEqual(center.alphaComponent, 0, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("menu-bar-\(scale)x.png"))
        }
    }

    func testHexagramKeepsSixSeparateInterwovenBands() throws {
        let bitmap = try renderIcon(scale: 10)
        var opaque = Set<Int>()
        let side = bitmap.pixelsWide
        for y in 0..<side {
            for x in 0..<side {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                if color.alphaComponent > 0.5 { opaque.insert(y * side + x) }
            }
        }
        XCTAssertGreaterThan(opaque.count, side * side / 8)
        XCTAssertLessThan(opaque.count, side * side / 3)
        var bands = 0
        while let start = opaque.first {
            bands += 1
            var pending = [start]
            opaque.remove(start)
            while let pixel = pending.popLast() {
                for neighbor in [pixel - 1, pixel + 1, pixel - side, pixel + side] {
                    if opaque.remove(neighbor) != nil { pending.append(neighbor) }
                }
            }
        }
        XCTAssertEqual(bands, 6, "The reference has six open bands, not a solid star or intersecting outlines")
    }

    func testSidebarBrandRendersWithTheApplicationIconAtMinimumWindowSize() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let icon = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")))
        XCTAssertTrue(AppBranding.applicationIcon === NSApplication.shared.applicationIconImage)
        fixture.window.contentView = NSHostingView(rootView: (LibraryView(
            model: fixture.model, product: ProductMetadataTestSupport.product, applicationIcon: icon)
            .tint(AppColors.brandAccent)).environment(\.locale, Locale(identifier: "zh-Hans")))
        fixture.model.section = .library
        fixture.model.selectedMediaID = nil
        fixture.model.selectedEntryID = nil

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await fixture.show(appearance: appearance)
            fixture.window.setContentSize(NSSize(width: 1000, height: 650))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let brand = try XCTUnwrap(descendants(of: fixture.window).first {
                $0.accessibilityIdentifier?() == "sidebar-brand"
            })
            XCTAssertEqual(brand.accessibilityLabel?(), ProductMetadataTestSupport.product.displayName)
            let bounds = fixture.window.convertFromScreen(try XCTUnwrap(brand.accessibilityFrame?()))
            XCTAssertGreaterThan(bounds.width, 120)
            XCTAssertLessThanOrEqual(bounds.maxX, 205)
            XCTAssertGreaterThanOrEqual(bounds.minX, 0)
            XCTAssertTrue(try XCTUnwrap(fixture.window.contentView).bounds.contains(bounds))
            _ = try await fixture.capture("\(name)-branding-minimum")
        }
    }

    private func renderIcon(scale: Int) throws -> NSBitmapImageRep {
        let side = 18 * scale
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        AppBranding.menuBarIcon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        return bitmap
    }

    private func descendants(of element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).flatMap { descendants(of: $0 as AnyObject) }
    }
}
