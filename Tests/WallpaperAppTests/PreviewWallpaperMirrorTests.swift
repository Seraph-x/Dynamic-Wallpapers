@testable import WallpaperNative
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class PreviewWallpaperMirrorTests: XCTestCase {
    func testShutdownDrainsMirrorBeforeDestroyingItsPreviewSource() async throws {
        let fixture = try SettingsPresentationFixture { AnyView(PreviewBackgroundContent(model: $0)) }
        defer { fixture.close() }
        let candidate = try imageItem(color: .blue, at: fixture.output.appendingPathComponent("shutdown-preview.png"))
        XCTAssertTrue(fixture.model.mutate { $0.media = [candidate] })
        fixture.model.section = .library
        fixture.model.selectedMediaID = candidate.id
        fixture.window.setContentSize(NSSize(width: 900, height: 700))
        try await fixture.show(readyText: "播放预览")
        try await waitForInspectorUI(fixture)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Inspector ready") { !fixture.model.inspectorMedia.isChecking }
        XCTAssertEqual(try fixture.element("播放预览", role: .button).accessibilityPerformPress?(), true)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Preview playing") {
            self.inlineSurface(in: fixture.window.contentView)?.isPlaying == true
        }
        let screen = try XCTUnwrap(fixture.window.screen)
        let mirror = try fixture.model.makeWallpaperMirror(on: screen)
        mirror.onFailure = { XCTFail($0.localizedDescription) }
        try await mirror.start(initialImage: fixture.model.captureWallpaper(on: screen))
        try await fixture.model.shutdownAndWait()
        XCTAssertTrue(mirror.isClosed)
        XCTAssertEqual(fixture.model.previewLifetime.activeDesktopSurfaceCount, 0)
        XCTAssertNil(fixture.model.failure)
    }

    func testSharedPreviewButtonChangesFullscreenBackgroundAndRestoresOriginalAcrossSpaces() async throws {
        let fixture = try SettingsPresentationFixture { AnyView(PreviewBackgroundContent(model: $0)) }
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 1)))
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        fixture.window.setContentSize(NSSize(width: 1100, height: 720))
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(screen.wallpaperID)
        let original = try imageItem(color: .red, at: fixture.output.appendingPathComponent("original-red.png"))
        let candidate = try imageItem(color: .blue, at: fixture.output.appendingPathComponent("preview-blue.png"))
        XCTAssertTrue(fixture.model.mutate {
            $0.media = [original, candidate]
            $0.displays = [DisplayBinding(id: displayID, source: .media(original.id, audio: AudioSettings()))]
        })
        fixture.model.section = .library
        fixture.model.selectedMediaID = candidate.id
        try await fixture.show(readyText: "播放预览")
        try await waitForInspectorUI(fixture)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Original wallpaper and inspector ready") {
            fixture.model.statuses.values.contains { $0.hasPrefix("正在播放") } && !fixture.model.inspectorMedia.isChecking
        }
        let saved = try Data(contentsOf: fixture.model.store.url)
        let appearance = fixture.model.library.settings.appearance
        try await WallpaperMirrorTestSupport.setFullScreen(true, window: fixture.window)
        try await waitForMirror(fixture.window)
        try await assertBackground(fixture, phase: "before-preview", red: 1, blue: 0)

        XCTAssertEqual(try fixture.element("播放预览", role: .button).accessibilityPerformPress?(), true)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Both preview copies playing") {
            self.inlineSurface(in: fixture.window.contentView)?.isPlaying == true
        }
        XCTAssertGreaterThan(fixture.model.previewLifetime.activeDesktopSurfaceCount, 0)
        try await assertBackground(fixture, phase: "preview-fullscreen", red: 0, blue: 1)
        let captured = try await fixture.model.captureWallpaper(on: screen)
        try assertColor(captured, red: 0, blue: 1)
        XCTAssertEqual(try Data(contentsOf: fixture.model.store.url), saved)

        try await WallpaperMirrorTestSupport.setFullScreen(false, window: fixture.window)
        XCTAssertTrue(inlineSurface(in: fixture.window.contentView)?.isPlaying == true)
        XCTAssertGreaterThan(fixture.model.previewLifetime.activeDesktopSurfaceCount, 0)
        try await WallpaperMirrorTestSupport.setFullScreen(true, window: fixture.window)
        try await waitForMirror(fixture.window)
        try await assertBackground(fixture, phase: "preview-reentered", red: 0, blue: 1)

        XCTAssertEqual(try fixture.element("停止预览", role: .button).accessibilityPerformPress?(), true)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Preview fully released") {
            fixture.model.previewLifetime.activeSurfaceCount == 0
        }
        try await assertBackground(fixture, phase: "restored-fullscreen", red: 1, blue: 0)
        XCTAssertEqual(fixture.model.library.settings.appearance, appearance)
        XCTAssertEqual(try Data(contentsOf: fixture.model.store.url), saved)
        XCTAssertNil(fixture.model.failure)
        try await WallpaperMirrorTestSupport.setFullScreen(false, window: fixture.window)
        try await fixture.model.shutdownAndWait()
    }

    private func waitForInspectorUI(_ fixture: SettingsPresentationFixture) async throws {
        // Inspection may finish before SwiftUI exposes the controls to accessibility.
        try await WallpaperMirrorTestSupport.waitUntil(description: "Inspector accessibility tree") {
            fixture.contains("壁纸详情")
        }
    }

    private func waitForMirror(_ window: NSWindow) async throws {
        try await WallpaperMirrorTestSupport.waitUntil(description: "Fullscreen mirror rendering") {
            WallpaperMirrorTestSupport.mirrorView(in: window)?.videoLayer.sampleBufferRenderer.status == .rendering
        }
    }

    private func assertBackground(_ fixture: SettingsPresentationFixture, phase: String,
                                  red: CGFloat, blue: CGFloat) async throws {
        try await Task.sleep(for: .milliseconds(700))
        let bitmap = try await WindowCompositorCapture.capture(fixture.window,
            to: fixture.output.appendingPathComponent("\(phase).png"))
        let color = try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        XCTAssertEqual(color.redComponent, red, accuracy: 0.08, phase)
        XCTAssertEqual(color.blueComponent, blue, accuracy: 0.08, phase)
    }

    private func assertColor(_ image: CGImage, red: CGFloat, blue: CGFloat) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        XCTAssertEqual(color.redComponent, red, accuracy: 0.08)
        XCTAssertEqual(color.blueComponent, blue, accuracy: 0.08)
    }

    private func inlineSurface(in view: NSView?) -> MediaSurface? {
        guard let view else { return nil }
        if let surface = view as? MediaSurface { return surface }
        return view.subviews.lazy.compactMap { self.inlineSurface(in: $0) }.first
    }

    private func imageItem(color: NSColor, at url: URL) throws -> MediaItem {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return MediaItem(url: url, kind: .image, width: 32, height: 32)
    }
}

private struct PreviewBackgroundContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
            InspectorView(model: model).frame(width: 330)
        }
        .appGlassBackground(.window, appearance: model.library.settings.appearance,
                            captureWallpaper: model.captureWallpaper, makeWallpaperMirror: model.makeWallpaperMirror)
    }
}
