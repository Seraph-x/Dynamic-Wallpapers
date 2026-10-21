@testable import WallpaperNative
import XCTest
import AppKit
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class DesktopGeometryTests: XCTestCase {
    func testActualDesktopSwapPreservesPlayingVideoOnFailure() async throws {
        _ = NSApplication.shared
        let url = try await VideoIntegrationTests.makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let item = try await MediaProbe.inspect(url)
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main))
        window.updateGeometry(frame: CGRect(x: 50, y: 50, width: 256, height: 144), scale: 1)
        defer { window.shutdown() }
        try await window.prepare(item: item, fit: .fill, entry: PlaylistEntry(mediaID: item.id))
        _ = await window.transition(duration: 0.05, paused: false)
        let visible = try XCTUnwrap(window.contentView?.subviews.first as? MediaSurface)
        XCTAssertTrue(visible.isPlaying)
        XCTAssertEqual(visible.alphaValue, 1)
        let missing = MediaItem(url: url.appendingPathExtension("missing"), kind: .video, width: 64, height: 64)
        do { try await window.prepare(item: missing, fit: .fill, entry: PlaylistEntry(mediaID: missing.id)); XCTFail("Missing file must fail") }
        catch { XCTAssertNotNil(error as? WallpaperError) }
        XCTAssertEqual(window.contentView?.subviews.count, 1)
        XCTAssertTrue(window.contentView?.subviews.first === visible)
        XCTAssertTrue(visible.isPlaying)
        try await window.prepare(item: item, fit: .fill, entry: PlaylistEntry(mediaID: item.id))
        XCTAssertEqual(window.contentView?.subviews.count, 2)
        XCTAssertTrue(visible.isPlaying)
        _ = await window.transition(duration: 0.05, paused: false)
        XCTAssertEqual(window.contentView?.subviews.count, 1)
        XCTAssertFalse(visible.isPlaying)
        XCTAssertNil(visible.superview)
    }

    func testDesktopWindowTracksNewGeometry() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = DesktopWindow(screen: screen)
        defer { window.shutdown() }
        let frame = CGRect(x: 130, y: 70, width: 640, height: 360)
        window.updateGeometry(frame: frame, scale: 1)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(window.contentView?.bounds.size, frame.size)
    }
}
