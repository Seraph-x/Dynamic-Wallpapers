import AppKit
import ScreenCaptureKit
import WallpaperCore

typealias WallpaperSnapshotCapture = @MainActor (NSScreen) async throws -> CGImage

@MainActor
enum WallpaperSnapshot {
    static func capture(window: NSWindow) async throws -> CGImage {
        guard window.isVisible, let windowID = CGWindowID(exactly: window.windowNumber), windowID != 0 else {
            throw WallpaperError("壁纸窗口当前不可见，无法定格画面。")
        }
        let size = window.frame.size
        let scale = window.backingScaleFactor
        if #available(macOS 14.4, *) {
            // This list contains our own windows without requiring Screen Recording permission.
            let content = try await SCShareableContent.currentProcess
            try Task.checkCancellation()
            guard let source = content.windows.first(where: { $0.windowID == windowID }) else {
                throw WallpaperError("未找到当前壁纸窗口，无法定格画面。")
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int((size.width * scale).rounded())
            configuration.height = Int((size.height * scale).rounded())
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: configuration)
            try Task.checkCancellation()
            return image
        } else {
            // macOS 14.0–14.3 use the equivalent own-window capture API.
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                      [.boundsIgnoreFraming, .bestResolution]) else {
                throw WallpaperError("无法截取当前壁纸画面。")
            }
            return image
        }
    }

    static func systemWallpaper(on screen: NSScreen) throws -> CGImage {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) else {
            throw WallpaperError("无法读取此显示器的系统壁纸。")
        }
        return try renderSystemImage(image, size: screen.frame.size, scale: screen.backingScaleFactor,
            options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
    }

    static func composite(_ foreground: CGImage, over background: CGImage) throws -> CGImage {
        guard let colors = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: background.width, height: background.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colors,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WallpaperError("无法合成淡入中的壁纸画面。")
        }
        let rect = CGRect(x: 0, y: 0, width: background.width, height: background.height)
        context.draw(background, in: rect)
        context.draw(foreground, in: rect)
        guard let result = context.makeImage() else { throw WallpaperError("壁纸画面合成失败。") }
        return result
    }

    static func renderSystemImage(_ image: NSImage, size: CGSize, scale: CGFloat,
                                 options: [NSWorkspace.DesktopImageOptionKey: Any]) throws -> CGImage {
        guard size.width > 0, size.height > 0, scale > 0,
              image.size.width.isFinite, image.size.height.isFinite, image.size.width > 0, image.size.height > 0,
              let width = Int(exactly: (size.width * scale).rounded()), width > 0,
              let height = Int(exactly: (size.height * scale).rounded()), height > 0,
              let colors = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: colors, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WallpaperError("无法创建系统壁纸的定格画面。")
        }
        canvas.scaleBy(x: scale, y: scale)
        let context = NSGraphicsContext(cgContext: canvas, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let fill = options[.fillColor] as? NSColor ?? .black
        fill.withAlphaComponent(1).setFill()
        CGRect(origin: .zero, size: size).fill()
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
            ?? .scaleProportionallyUpOrDown
        let clips = (options[.allowClipping] as? NSNumber)?.boolValue ?? false
        let destination = try imageRect(imageSize: image.size, size: size, scaling: scaling, clips: clips)
        image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
        guard let result = canvas.makeImage() else { throw WallpaperError("系统壁纸画面解码失败。") }
        return result
    }

    private static func imageRect(imageSize: CGSize, size: CGSize, scaling: NSImageScaling, clips: Bool) throws -> CGRect {
        let rendered: CGSize
        switch scaling {
        case .scaleAxesIndependently: rendered = size
        case .scaleNone: rendered = imageSize
        case .scaleProportionallyDown, .scaleProportionallyUpOrDown:
            let ratios = (size.width / imageSize.width, size.height / imageSize.height)
            let factor = clips ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)
            let limited = scaling == .scaleProportionallyDown ? min(1, factor) : factor
            rendered = CGSize(width: imageSize.width * limited, height: imageSize.height * limited)
        @unknown default: throw WallpaperError("无法识别系统壁纸的缩放方式。")
        }
        return CGRect(x: (size.width - rendered.width) / 2, y: (size.height - rendered.height) / 2,
                      width: rendered.width, height: rendered.height)
    }
}
