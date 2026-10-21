import AppKit
import SwiftUI
import WallpaperCore

struct AppPalette {
    let brandAccent: Color
    let selectionBackground: Color
    let selectionIndicator: Color

    init(accentColor: AppAccentColor) {
        let accent = AppColors.sRGB(accentColor)
        brandAccent = Color(nsColor: accent)
        selectionBackground = AppColors.adaptive(
            light: accent.withAlphaComponent(0.12), dark: accent.withAlphaComponent(0.15))
        selectionIndicator = accentColor == .defaultAccent
            ? AppColors.adaptive(light: AppColors.sRGB(AppAccentColor(red: 0x50, green: 0x7A, blue: 0x9D)),
                                 dark: accent)
            : AppColors.adaptiveIndicator(accent)
    }
}

private struct AppPaletteKey: EnvironmentKey {
    static let defaultValue = AppPalette(accentColor: .defaultAccent)
}

extension EnvironmentValues {
    var appPalette: AppPalette {
        get { self[AppPaletteKey.self] }
        set { self[AppPaletteKey.self] = newValue }
    }
}

extension View {
    func appTheme(_ appearance: AppAppearanceSettings) -> some View {
        let palette = AppPalette(accentColor: appearance.accentColor)
        return tint(palette.brandAccent).environment(\.appPalette, palette)
    }
}

enum AppColors {
    private static let defaultPalette = AppPalette(accentColor: .defaultAccent)
    static let brandAccent = defaultPalette.brandAccent
    static let selectionBackground = defaultPalette.selectionBackground
    static let selectionIndicator = defaultPalette.selectionIndicator
    static let secondaryActionText = adaptive(light: sRGB(0x4B5563), dark: sRGB(0xD1D5DB))

    static func accentColor(from color: Color) -> AppAccentColor? {
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt8 {
            UInt8((min(max(component, 0), 1) * 255).rounded())
        }
        return AppAccentColor(red: byte(value.redComponent), green: byte(value.greenComponent),
                              blue: byte(value.blueComponent))
    }

    static func sRGB(_ color: AppAccentColor) -> NSColor {
        NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255, alpha: 1)
    }

    fileprivate static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    fileprivate static func adaptiveIndicator(_ accent: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var semanticSurfaces: [NSColor] = []
            appearance.performAsCurrentDrawingAppearance {
                semanticSurfaces = [NSColor.windowBackgroundColor, NSColor.controlBackgroundColor]
            }
            let fallback = dark ? NSColor(white: 0.12, alpha: 1) : .white
            let surfaces = (semanticSurfaces + [fallback]).compactMap { $0.usingColorSpace(.sRGB) }
            let opacity: CGFloat = dark ? 0.15 : 0.12
            let target: NSColor = dark ? .white : .black
            for step in 0...20 {
                let candidate = mix(accent, target, fraction: CGFloat(step) / 20)
                if surfaces.allSatisfy({ surface in
                    contrast(candidate, over: accent.withAlphaComponent(opacity), surface) >= 3
                }) { return candidate }
            }
            return target
        })
    }

    private static func sRGB(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    private static func mix(_ first: NSColor, _ second: NSColor, fraction: CGFloat) -> NSColor {
        let first = first.usingColorSpace(.sRGB) ?? first
        let second = second.usingColorSpace(.sRGB) ?? second
        return NSColor(srgbRed: first.redComponent * (1 - fraction) + second.redComponent * fraction,
                       green: first.greenComponent * (1 - fraction) + second.greenComponent * fraction,
                       blue: first.blueComponent * (1 - fraction) + second.blueComponent * fraction, alpha: 1)
    }

    private static func contrast(_ foreground: NSColor, over selection: NSColor, _ background: NSColor) -> CGFloat {
        let composite = over(selection, background)
        let first = luminance(foreground), second = luminance(composite)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func over(_ foreground: NSColor, _ background: NSColor) -> NSColor {
        let alpha = foreground.alphaComponent
        return NSColor(srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
                       green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
                       blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let value = color.usingColorSpace(.sRGB) ?? color
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(value.redComponent) + 0.7152 * linear(value.greenComponent)
            + 0.0722 * linear(value.blueComponent)
    }
}
