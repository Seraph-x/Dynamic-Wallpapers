@testable import WallpaperNative
import AppKit
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class ApplicationResidencyIntegrationTests: XCTestCase {
    func testRealDockSwitchHideAndWindowCloseKeepTheSamePlayingSurface() async throws {
        let fixture = try SelectionAppearanceFixture()
        let managementWindows = ManagementWindowObserver(onChange: fixture.model.setManagementWindowsOpen)
        managementWindows.start()
        defer {
            managementWindows.stop()
            NSApplication.shared.unhide(nil)
            XCTAssertTrue(NSApplication.shared.setActivationPolicy(.regular))
            fixture.close()
        }
        try await fixture.show(appearance: .aqua)
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let item = try XCTUnwrap(fixture.model.library.media.first)
        fixture.model.applyMedia(item, displayID: try XCTUnwrap(NSScreen.main?.wallpaperID), fit: .fill)
        try await waitForWallpaper(fixture.model)
        let desktop = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let surface = try XCTUnwrap(desktop.contentView?.subviews.compactMap { $0 as? any PlaybackSurface }.first)
        XCTAssertEqual(surface.state, .playing)

        for showDock in [false, true, false] {
            XCTAssertTrue(fixture.model.setShowDockIcon(showDock))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(NSApplication.shared.activationPolicy(), .regular,
                           "Open management windows retain the application menu regardless of the saved Dock setting")
            XCTAssertEqual(try fixture.model.store.load().settings.showDockIcon, showDock)
            XCTAssertTrue(fixture.window.isVisible)
            assertSameWallpaper(desktop, surface: surface)
        }

        NSApplication.shared.hide(nil)
        try await waitForApplicationHide(fixture.window)
        XCTAssertTrue(NSApplication.shared.isHidden)
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .regular, "Hiding the app is not closing its windows")
        assertSameWallpaper(desktop, surface: surface)
        let onScreen = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]])
        XCTAssertTrue(onScreen.contains { ($0[kCGWindowNumber as String] as? Int) == desktop.windowNumber },
                      "The wallpaper must remain on screen, not merely retain its view")

        NSApplication.shared.unhide(nil)
        fixture.window.performClose(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.window.isVisible)
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .accessory)
        XCTAssertFalse(fixture.model.isShuttingDown)
        assertSameWallpaper(desktop, surface: surface)
        try await fixture.model.shutdownAndWait()
        XCTAssertFalse(desktop.isVisible)
        XCTAssertEqual(surface.state, .closed)
    }

    private func assertSameWallpaper(_ desktop: DesktopWindow, surface: any PlaybackSurface,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(desktop.hasVisibleWallpaper, file: file, line: line)
        XCTAssertEqual(desktop.activeSurfaceCount, 1, file: file, line: line)
        XCTAssertTrue(surface.view.superview === desktop.contentView, file: file, line: line)
        XCTAssertEqual(surface.state, .playing, file: file, line: line)
    }

    private func waitForWallpaper(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.statuses.values.contains(where: { $0.hasPrefix("正在播放") }) {
            if let failure = model.failure { throw failure }
            guard ContinuousClock.now < deadline else { throw WallpaperError("Residency fixture did not display wallpaper") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForApplicationHide(_ window: NSWindow) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !NSApplication.shared.isHidden || window.isVisible {
            // XCTest does not run NSApplication.run(); dispatch the native hide event.
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                              inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("Application hide did not complete: active=\(NSApplication.shared.isActive), hidden=\(NSApplication.shared.isHidden), windowVisible=\(window.isVisible)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
