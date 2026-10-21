import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class FullScreenWallpaperTests: XCTestCase {
    func testCustomNativeFullScreenRoundTripRestoresFrameAndLeavesOtherWindowUntouched() async throws {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        if originalPolicy != .regular { XCTAssertTrue(app.setActivationPolicy(.regular)) }
        defer {
            if app.activationPolicy() != originalPolicy { XCTAssertTrue(app.setActivationPolicy(originalPolicy)) }
        }
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 900, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        let bridge = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: false)
        window.contentView = bridge
        defer { window.close() }
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await waitForKeyWindow(window)
        let screen = try XCTUnwrap(window.screen)
        let normalFrame = window.frame
        let appOptions = app.presentationOptions

        let unrelated = NSWindow(contentRect: NSRect(x: 40, y: 60, width: 420, height: 300),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        let unrelatedDelegate = FullScreenIsolationDelegate()
        unrelated.delegate = unrelatedDelegate
        let unrelatedFrame = unrelated.frame
        let unrelatedAlpha = unrelated.alphaValue
        let unrelatedBehavior = unrelated.collectionBehavior
        defer { unrelated.close() }

        let notifications = FullScreenNotificationCounts()
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window,
                               queue: .main) { _ in MainActor.assumeIsolated { notifications.willEnter += 1 } },
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window,
                               queue: .main) { _ in MainActor.assumeIsolated { notifications.didEnter += 1 } },
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window,
                               queue: .main) { _ in MainActor.assumeIsolated { notifications.willExit += 1 } },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window,
                               queue: .main) { _ in MainActor.assumeIsolated { notifications.didExit += 1 } },
        ]
        defer { tokens.forEach(center.removeObserver) }

        try await setFullScreen(true, window: window)
        assertFrame(window.frame, equals: screen.frame, accuracy: 2)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(notifications.willEnter, 1)
        XCTAssertEqual(notifications.didEnter, 1)

        try await setFullScreen(false, window: window)
        assertFrame(window.frame, equals: normalFrame, accuracy: 2)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(notifications.willExit, 1)
        XCTAssertEqual(notifications.didExit, 1)
        XCTAssertEqual(unrelated.frame, unrelatedFrame)
        XCTAssertEqual(unrelated.alphaValue, unrelatedAlpha)
        XCTAssertEqual(unrelated.collectionBehavior, unrelatedBehavior)
        XCTAssertTrue(unrelated.delegate === unrelatedDelegate)
        XCTAssertEqual(app.presentationOptions, appOptions)
    }

    func testCustomNativeFullScreenExitRestoresToolbarDetachedDuringTransition() async throws {
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        if originalPolicy != .regular { XCTAssertTrue(app.setActivationPolicy(.regular)) }
        defer {
            if app.activationPolicy() != originalPolicy { XCTAssertTrue(app.setActivationPolicy(originalPolicy)) }
        }
        app.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 140, y: 160, width: 860, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: false)
        defer { window.close() }
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await waitForKeyWindow(window)
        let normalFrame = window.frame

        try await setFullScreen(true, window: window)
        let toolbar = NSToolbar(identifier: "native-fullscreen-exit-toolbar")
        window.toolbar = toolbar
        toolbar.isVisible = true

        try await setFullScreen(false, window: window)

        XCTAssertTrue(window.toolbar === toolbar)
        XCTAssertTrue(toolbar.isVisible)
        assertFrame(window.frame, equals: normalFrame, accuracy: 2)
    }

    func testFullScreenTracksWallpaperChangesAndExitRestoresTransparentBackground() async throws {
        let fixture = try SettingsPresentationFixture { AnyView(LiveFullScreenBackgroundFixture(model: $0)) }
        defer { fixture.close() }
        // Pixel comparisons below require the wallpaper without the saved glass tint.
        XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 1)))
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        fixture.window.setContentSize(NSSize(width: 1180, height: 760))
        try await fixture.showWindow()
        let screen = try XCTUnwrap(fixture.window.screen)
        let screenID = try XCTUnwrap(screen.wallpaperID)
        let red = try imageItem(color: .red, at: fixture.output.appendingPathComponent("red.png"))
        let blue = try imageItem(color: .blue, at: fixture.output.appendingPathComponent("blue.png"))
        XCTAssertTrue(fixture.model.mutate {
            $0.media = [red, blue]
            $0.displays = [DisplayBinding(id: screenID, source: .media(red.id, audio: AudioSettings()))]
        })
        try await waitForPlayback(fixture.model)
        XCTAssertNil(backgroundImage(in: fixture.window))

        try await setFullScreen(true, window: fixture.window)
        try await fixture.settle()
        try await WallpaperMirrorTestSupport.waitUntil(description: "Live background mounted") {
            WallpaperMirrorTestSupport.mirrorView(in: fixture.window) != nil
        }
        let initial = try await captureBackground(fixture, name: "live-initial-red")
        try assertColor(XCTUnwrap(initial.cgImage), red: 1, blue: 0)

        XCTAssertTrue(fixture.model.mutate {
            $0.displays[0].source = .media(blue.id, audio: AudioSettings())
        })
        try await Task.sleep(for: .milliseconds(900))
        let changed = try await captureBackground(fixture, name: "live-changed-blue")
        try assertColor(XCTUnwrap(changed.cgImage), red: 0, blue: 1)
        XCTAssertEqual(fixture.window.alphaValue, 1)

        try await setFullScreen(false, window: fixture.window)
        try await fixture.settle()
        XCTAssertNil(backgroundImage(in: fixture.window), "Exit must release the fullscreen background")

        try await setFullScreen(true, window: fixture.window)
        try await fixture.settle()
        let reentered = try await captureBackground(fixture, name: "live-reentered-blue")
        try assertColor(XCTUnwrap(reentered.cgImage), red: 0, blue: 1)
        try await setFullScreen(false, window: fixture.window)
        try await fixture.model.shutdownAndWait()
    }

    func testLibrarySettingsAndTranscodeWindowsMountScreenSizedLiveBackgrounds() async throws {
        let contents: [(String, String, (AppModel) -> AnyView)] = [
            ("library", "导入壁纸", { AnyView(LibraryView(model: $0, product: ProductMetadataTestSupport.product)) }),
            ("settings", "外观", { AnyView(SettingsView(model: $0, product: ProductMetadataTestSupport.product)) }),
            ("transcode", "视频转码", { AnyView(TranscodeView(model: $0)) })
        ]
        for (name, readyText, content) in contents {
            let fixture = try SettingsPresentationFixture(content: content)
            defer { fixture.close() }
            fixture.window.styleMask.insert(.resizable)
            fixture.window.collectionBehavior.insert(.fullScreenPrimary)
            fixture.window.setContentSize(NSSize(width: 1180, height: 760))
            try await fixture.show(readyText: readyText)
            let screenID = try XCTUnwrap(fixture.window.screen?.wallpaperID)
            let item = try imageItem(color: .red, at: fixture.output.appendingPathComponent("\(name)-wallpaper.png"))
            XCTAssertTrue(fixture.model.mutate {
                $0.media = [item]
                $0.displays = [DisplayBinding(id: screenID, source: .media(item.id, audio: AudioSettings()))]
            })
            try await waitForPlayback(fixture.model)
            try await setFullScreen(true, window: fixture.window)
            try await WallpaperMirrorTestSupport.waitUntil(description: "\(name) live background mounted") {
                WallpaperMirrorTestSupport.mirrorView(in: fixture.window)?.videoLayer.sampleBufferRenderer.status == .rendering
            }
            let view = try XCTUnwrap(WallpaperMirrorTestSupport.mirrorView(in: fixture.window))
            let contentBounds = try XCTUnwrap(fixture.window.contentView).bounds
            let screen = try XCTUnwrap(fixture.window.screen)
            XCTAssertGreaterThanOrEqual(fixture.window.frame.width, screen.frame.width - 2, name)
            XCTAssertGreaterThanOrEqual(view.bounds.width, contentBounds.width - 2, name)
            XCTAssertGreaterThanOrEqual(view.bounds.height, contentBounds.height - 2, name)
            try await setFullScreen(false, window: fixture.window)
            try await fixture.model.shutdownAndWait()
            XCTAssertNil(WallpaperMirrorTestSupport.mirrorView(in: fixture.window), name)
        }
    }

    func testFullScreenBackgroundPreservesAppearanceAndReduceTransparency() async throws {
        let checkerboard = try makeCheckerboard()
        for reduced in [false, true] where reduced || !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let fixture = try SettingsPresentationFixture {
                AnyView(FullScreenBackgroundFixture(model: $0, image: checkerboard, reducesTransparency: reduced))
            }
            defer { fixture.close() }
            // Establish the 100% reference explicitly; the product default is 75%.
            XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 1)))
            fixture.window.styleMask.insert(.resizable)
            fixture.window.collectionBehavior.insert(.fullScreenPrimary)
            try await fixture.showWindow()
            try await setFullScreen(true, window: fixture.window)
            try await fixture.settle()
            let reference = try await captureBackground(fixture, name: "full-\(reduced)-transparent")
            var materials: [NSBitmapImageRep] = []
            for style in GlassBlurStyle.allCases {
                XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 0.5, blur: style)))
                try await fixture.settle()
                let rendered = try await captureBackground(fixture, name: "full-\(reduced)-\(style)")
                let difference = try backgroundDifference(reference, rendered)
                if reduced || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                    XCTAssertLessThan(difference, 0.015, "Reduce Transparency keeps an opaque background")
                } else {
                    XCTAssertGreaterThan(difference, 0.05, "The transparency slider must affect the frozen background")
                }
                materials.append(rendered)
                XCTAssertEqual(fixture.window.alphaValue, 1, "Foreground opacity must stay unchanged")
            }
            if !reduced && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                XCTAssertGreaterThan(try backgroundDifference(materials[0], materials[1]), 0.01,
                                     "Clear and frosted must remain visibly different in full screen")
            }
            XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(transparency: 0)))
            try await fixture.settle()
            let opaque = try await captureBackground(fixture, name: "full-\(reduced)-opaque")
            XCTAssertEqual(try backgroundDifference(reference, opaque) < 0.015, reduced,
                           "Only Reduce Transparency makes 100% and 0% look the same")
            try await setFullScreen(false, window: fixture.window)
            try await fixture.model.shutdownAndWait()
        }
    }

    func testAttachingToAnAlreadyFullScreenWindowDefersStatePublication() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        try await fixture.show()
        try await setFullScreen(true, window: fixture.window)
        let image = try makeCheckerboard()
        let state = FullScreenWallpaperState()
        let observer = FullScreenWallpaperObserver.WindowView(state: state, capture: { _ in image })
        let shown = expectation(description: "reattached full-screen background displayed")
        let imageSubscription = state.$image.sink { if $0 === image { shown.fulfill() } }
        var mounting = true
        let subscription = state.objectWillChange.sink {
            XCTAssertFalse(mounting, "viewDidMoveToWindow can run inside SwiftUI's graph update")
        }
        fixture.window.contentView?.addSubview(observer)
        mounting = false
        await fulfillment(of: [shown], timeout: 2)
        XCTAssertTrue(state.image === image)
        observer.removeFromSuperview()
        try await fixture.settle()
        XCTAssertNil(state.image)
        withExtendedLifetime((subscription, imageSubscription)) {}
        try await setFullScreen(false, window: fixture.window)
        try await fixture.model.shutdownAndWait()
    }

    func testFirstFadeIncludesTheSystemWallpaperUnderlayInTheFrozenImage() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        let screen = try XCTUnwrap(fixture.window.screen)
        let screenID = try XCTUnwrap(screen.wallpaperID)
        let item = try imageItem(color: .red, at: fixture.output.appendingPathComponent("fade.png"))
        let playlist = Playlist(name: "First fade", entries: [PlaylistEntry(mediaID: item.id)], transition: 3)
        XCTAssertTrue(fixture.model.mutate {
            $0.media = [item]
            $0.playlists = [playlist]
            $0.displays = [DisplayBinding(id: screenID, playlistID: playlist.id)]
        })
        let deadline = ContinuousClock.now + .seconds(3)
        while !fixture.model.statuses.values.contains(where: { $0.hasPrefix("切换中") }) {
            if let failure = fixture.model.failure { throw failure }
            guard ContinuousClock.now < deadline else { throw WallpaperError("First fade did not start") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        let image = try await fixture.model.captureWallpaper(on: screen)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let pixel = try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.001,
                       "The original system wallpaper must remain underneath an unfinished first fade")
        try await fixture.model.shutdownAndWait()
    }

    func testCaptureFailureShowsAnActionableAlertFromTheBackground() async throws {
        let fixture = try SettingsPresentationFixture { _ in
            AnyView(Color.clear.appGlassBackground(.window, captureWallpaper: { _ in
                throw WallpaperError("当前壁纸无法取帧")
            }))
        }
        defer { fixture.close() }
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        try await fixture.showWindow()
        try await setFullScreen(true, window: fixture.window)
        try await fixture.settle()
        XCTAssertTrue(fixture.contains("全屏背景无法显示"))
        XCTAssertTrue(fixture.contains("当前壁纸无法取帧"))
        let button = try fixture.element("好", role: .button)
        XCTAssertNotNil(button.accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertNil(fixture.window.attachedSheet)
        XCTAssertFalse(fixture.contains("当前壁纸无法取帧"))
        try await setFullScreen(false, window: fixture.window)
        try await fixture.model.shutdownAndWait()
    }

    func testCaptureFailureTranslatesItsSummaryAndKeepsDiagnosticDetails() async throws {
        let diagnostic = "CGWindowListCreateImage: capture failed for 海岸 100% %@"
        let fixture = try SettingsPresentationFixture { _ in
            AnyView(Color.clear.appGlassBackground(.window, captureWallpaper: { _ in
                throw WallpaperError("无法截取当前壁纸画面。", diagnostic: diagnostic)
            }))
        }
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.setLanguage(.english))
        fixture.window.styleMask.insert(.resizable)
        fixture.window.collectionBehavior.insert(.fullScreenPrimary)
        try await fixture.showWindow()
        try await setFullScreen(true, window: fixture.window)
        try await fixture.settle()
        XCTAssertTrue(fixture.contains("Cannot Show Full-screen Background"))
        XCTAssertTrue(fixture.contains("Cannot capture the current wallpaper.\n\n\(diagnostic)"))
        XCTAssertNotNil(try fixture.element("OK", role: .button).accessibilityPerformPress?())
        try await fixture.settle()
        try await setFullScreen(false, window: fixture.window)
        try await fixture.model.shutdownAndWait()
    }

    private func captureBackground(_ fixture: SettingsPresentationFixture, name: String) async throws -> NSBitmapImageRep {
        try await WindowCompositorCapture.capture(fixture.window, to: fixture.output.appendingPathComponent("\(name).png"))
    }

    private func backgroundDifference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) throws -> Double {
        var difference = 0.0
        var count = 0
        for y in stride(from: first.pixelsHigh / 4, to: first.pixelsHigh * 3 / 4, by: 31) {
            for x in stride(from: first.pixelsWide / 4, to: first.pixelsWide * 3 / 4, by: 31) {
                let a = try first.sRGBColor(atX: x, y: y)
                let b = try second.sRGBColor(atX: x, y: y)
                difference += max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                                  abs(a.blueComponent - b.blueComponent))
                count += 1
            }
        }
        return difference / Double(count)
    }

    private func assertFrame(_ actual: NSRect, equals expected: NSRect, accuracy: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func makeCheckerboard() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8,
            bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in stride(from: 0, to: 180, by: 8) {
            for x in stride(from: 0, to: 320, by: 8) {
                context.setFillColor((x / 8 + y / 8).isMultiple(of: 2) ? NSColor.white.cgColor : NSColor.black.cgColor)
                context.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func setFullScreen(_ enabled: Bool, window: NSWindow) async throws {
        var finished = false
        let name = enabled ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { finished = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.toggleFullScreen(nil)
        let deadline = ContinuousClock.now + .seconds(6)
        while !finished {
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                              inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard ContinuousClock.now < deadline else { throw WallpaperError("Native full-screen transition timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(window.styleMask.contains(.fullScreen), enabled)
    }

    private func waitForKeyWindow(_ window: NSWindow) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !window.isKeyWindow {
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                              inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard ContinuousClock.now < deadline else { throw WallpaperError("Test window failed to become key") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForPlayback(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !model.statuses.values.contains(where: { $0.hasPrefix("正在播放") }) {
            if let failure = model.failure { throw failure }
            guard ContinuousClock.now < deadline else { throw WallpaperError("Wallpaper did not start") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func backgroundImage(in window: NSWindow) -> CGImage? {
        func find(_ view: NSView) -> CGImage? {
            if view.identifier?.rawValue == "fullscreen-wallpaper", let contents = view.layer?.contents,
               CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return (contents as! CGImage) }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    private func assertColor(_ image: CGImage, red: CGFloat, blue: CGFloat) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try bitmap.sRGBColor(atX: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        XCTAssertEqual(color.redComponent, red, accuracy: 0.08)
        XCTAssertEqual(color.blueComponent, blue, accuracy: 0.08)
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

@MainActor
private final class FullScreenIsolationDelegate: NSObject, NSWindowDelegate {}

@MainActor
private final class FullScreenNotificationCounts {
    var willEnter = 0
    var didEnter = 0
    var willExit = 0
    var didExit = 0
}

private struct LiveFullScreenBackgroundFixture: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Color.clear.appGlassBackground(.window, appearance: model.library.settings.appearance,
                                       captureWallpaper: model.captureWallpaper, makeWallpaperMirror: model.makeWallpaperMirror)
    }
}

private struct FullScreenBackgroundFixture: View {
    @ObservedObject var model: AppModel
    let image: CGImage
    let reducesTransparency: Bool

    var body: some View {
        WindowGlassBackground(appearance: model.library.settings.appearance, reducesTransparency: reducesTransparency,
                              captureWallpaper: { _ in image })
            .ignoresSafeArea()
    }
}
