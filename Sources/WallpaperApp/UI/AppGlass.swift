import AppKit
import SwiftUI
import WallpaperCore

enum AppGlassSurface {
    case window, control

    var legacyMaterial: NSVisualEffectView.Material {
        switch self {
        case .window: return .sidebar
        case .control: return .popover
        }
    }

    var blendingMode: NSVisualEffectView.BlendingMode {
        self == .window ? .behindWindow : .withinWindow
    }

    var cornerRadius: CGFloat {
        switch self {
        case .window: return 0
        case .control: return 8
        }
    }
}

extension View {
    func appGlassBackground(_ surface: AppGlassSurface,
                            appearance: AppAppearanceSettings = AppAppearanceSettings(),
                            receivesTransparentClicks: Bool = false,
                            captureWallpaper: @escaping WallpaperSnapshotCapture = {
                                try WallpaperSnapshot.systemWallpaper(on: $0)
                            }, makeWallpaperMirror: WallpaperMirrorFactory? = nil) -> some View {
        background {
            AppGlassBackground(surface: surface, appearance: appearance,
                               receivesTransparentClicks: receivesTransparentClicks, captureWallpaper: captureWallpaper,
                               makeWallpaperMirror: makeWallpaperMirror)
                .ignoresSafeArea(.container, edges: surface == .window ? .all : [])
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    func appGlassPresentation(appearance: AppAppearanceSettings) -> some View {
        appGlassBackground(.window, appearance: appearance)
            .presentationBackground(.clear)
            .modifier(DismissPresentationOnQuit())
    }

    func appGlassOutlinedButtonStyle() -> some View {
        buttonStyle(AccentOutlineButtonStyle())
    }

    func appGlassControlStyle() -> some View {
        buttonStyle(CompactGlassControlStyle()).controlSize(.small)
    }
}

private struct DismissPresentationOnQuit: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .cancelPendingPresentationsForQuit)) { _ in
            dismiss()
        }
    }
}

private struct AccentOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.appPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppGlassSurface.control.cornerRadius)
        configuration.label
            .font(metrics.font.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .contentShape(shape)
            .overlay { shape.strokeBorder(palette.brandAccent, lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }

    private var metrics: (horizontal: CGFloat, vertical: CGFloat, font: Font) {
        switch controlSize {
        case .mini: return (8, 3, .caption2)
        case .small: return (10, 4, .caption)
        case .regular: return (12, 6, .body)
        case .large: return (16, 8, .body)
        case .extraLarge: return (20, 10, .title3)
        @unknown default: return (12, 6, .body)
        }
    }
}

private struct AppGlassBackground: View {
    let surface: AppGlassSurface
    let appearance: AppAppearanceSettings
    let receivesTransparentClicks: Bool
    let captureWallpaper: WallpaperSnapshotCapture
    let makeWallpaperMirror: WallpaperMirrorFactory?
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: surface.cornerRadius)
        if surface == .window {
            WindowGlassBackground(appearance: appearance, reducesTransparency: reducesTransparency,
                                  receivesTransparentClicks: receivesTransparentClicks,
                                  captureWallpaper: captureWallpaper, makeWallpaperMirror: makeWallpaperMirror)
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            // macOS 14/15 retain native semantic materials and accessibility behavior.
            NativeVisualEffectBackground(material: surface.legacyMaterial, blendingMode: surface.blendingMode)
                .clipShape(shape)
        }
    }
}

struct GlassControlGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            // Batch the effects without merging neighboring button outlines.
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
    }
}

private struct CompactGlassControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppGlassSurface.control.cornerRadius)
        let label = configuration.label
            .font(.caption)
            .foregroundStyle(AppColors.secondaryActionText)
            .frame(minWidth: 14, minHeight: 14)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(shape)
        if #available(macOS 26.0, *) {
            label.glassEffect(.regular.interactive(isEnabled), in: shape)
                .opacity(isEnabled ? 1 : 0.45)
        } else {
            label.appGlassBackground(.control)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }
    }
}
