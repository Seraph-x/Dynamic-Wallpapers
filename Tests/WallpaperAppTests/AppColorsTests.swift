import XCTest
import SwiftUI
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class AppColorsTests: XCTestCase {
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    func testBrandAccentUsesBFE2FFInBothAppearances() throws {
        for appearance in appearances {
            let actual = try resolve(AppColors.brandAccent, in: appearance)
            assertRGB(actual, equals: color(0xBFE2FF))
            XCTAssertEqual(actual.alphaComponent, 1, accuracy: 0.0001)
        }
    }

    func testSelectionBackgroundUsesBrandRGBAndApprovedOpacity() throws {
        for (appearance, opacity) in [(NSAppearance.Name.aqua, 0.12), (.darkAqua, 0.15)] {
            let background = try resolve(AppColors.selectionBackground, in: appearance)
            let brand = try resolve(AppColors.brandAccent, in: appearance)
            assertRGB(background, equals: brand)
            XCTAssertEqual(background.alphaComponent, opacity, accuracy: 0.0001)
        }
    }

    func testIndicatorUsesApprovedPaletteAndRemainsDistinctFromSelection() throws {
        for (appearance, hex) in [(NSAppearance.Name.aqua, 0x507A9D), (.darkAqua, 0xBFE2FF)] {
            let indicator = try resolve(AppColors.selectionIndicator, in: appearance)
            assertRGB(indicator, equals: color(hex))
            let fill = try resolve(AppColors.selectionBackground, in: appearance)
            for surface in try surfaces(in: appearance) {
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(indicator, over(fill, surface)), 3)
            }
        }
    }

    func testEnabledSecondaryActionTextMeetsAAOnAllApplicationSurfaces() throws {
        for (appearance, hex) in [(NSAppearance.Name.aqua, 0x4B5563), (.darkAqua, 0xD1D5DB)] {
            let text = try resolve(AppColors.secondaryActionText, in: appearance)
            assertRGB(text, equals: color(hex))
            let selection = try resolve(AppColors.selectionBackground, in: appearance)
            for surface in try surfaces(in: appearance) {
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(text, surface), 4.5)
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(text, over(selection, surface)), 4.5)
            }
        }
    }

    func testCustomAccentDrivesTintAndSelectionFillWithoutChangingItsRGB() throws {
        let custom = AppAccentColor(red: 0x12, green: 0xAB, blue: 0xEF)
        let palette = AppPalette(accentColor: custom)
        for (appearance, opacity) in [(NSAppearance.Name.aqua, 0.12), (.darkAqua, 0.15)] {
            let accent = try resolve(palette.brandAccent, in: appearance)
            assertRGB(accent, equals: color(0x12ABEF))
            let fill = try resolve(palette.selectionBackground, in: appearance)
            assertRGB(fill, equals: accent)
            XCTAssertEqual(fill.alphaComponent, opacity, accuracy: 0.0001)
        }
    }

    func testCustomSelectionIndicatorsRemainVisibleForExtremeAccentColors() throws {
        for custom in [AppAccentColor(red: 0, green: 0, blue: 0),
                       AppAccentColor(red: 255, green: 255, blue: 255),
                       AppAccentColor(red: 255, green: 0, blue: 0)] {
            let palette = AppPalette(accentColor: custom)
            for appearance in appearances {
                let indicator = try resolve(palette.selectionIndicator, in: appearance)
                let fill = try resolve(palette.selectionBackground, in: appearance)
                for surface in try surfaces(in: appearance) {
                    XCTAssertGreaterThanOrEqual(ColorContrast.ratio(indicator, over(fill, surface)), 3)
                }
            }
        }
    }

    private func surfaces(in appearance: NSAppearance.Name) throws -> [NSColor] {
        try [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor),
             appearance == .aqua ? Color.white : Color(white: 0.12)].map { try resolve($0, in: appearance) }
    }

    private func resolve(_ color: Color, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance { result = NSColor(color).usingColorSpace(.sRGB) }
        return try XCTUnwrap(result)
    }

    private func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    private func assertRGB(_ actual: NSColor, equals expected: NSColor,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.0001, file: file, line: line)
    }

    private func over(_ foreground: NSColor, _ background: NSColor) -> NSColor {
        let alpha = foreground.alphaComponent
        return NSColor(srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
                       green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
                       blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
    }

}
