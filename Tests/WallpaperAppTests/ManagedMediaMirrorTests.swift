import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ManagedMediaMirrorTests: XCTestCase {
    func testRemovalWaitsForMirrorsToReleaseTheRetiredWallpaper() async throws {
        let gate = ManagedReadGate()
        let screen = try XCTUnwrap(NSScreen.main)
        let displayID = try XCTUnwrap(screen.wallpaperID)
        let factory = ControlledFactory()
        let coordinator = DesktopCoordinator(surfaceFactory: factory, screenProvider: { [displayID: screen] },
            mirrorStreamFactory: { _, view in
                WallpaperMirrorStream(driver: WallpaperCaptureDriver(start: {}, stop: { await gate.wait() }, removeOutput: {}),
                    output: WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer))
            })
        defer { gate.release(); coordinator.shutdown() }
        let item = MediaItem(url: URL(fileURLWithPath: "/test.png"), kind: .image, width: 32, height: 32)
        var library = Library.empty
        library.media = [item]
        library.playlists = [Playlist(name: "test", entries: [PlaylistEntry(mediaID: item.id)], transition: 0)]
        library.displays = [DisplayBinding(id: displayID, playlistID: library.playlists[0].id)]
        let displayed = expectation(description: "wallpaper displayed")
        coordinator.onCommit = { _, _ in displayed.fulfill() }
        coordinator.reconcile(library)
        await fulfillment(of: [displayed], timeout: 2)
        let surface = try XCTUnwrap(factory.surfaces.first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let mirror = try coordinator.makeWallpaperMirror(on: screen)
        try await mirror.start(initialImage: XCTUnwrap(bitmap.cgImage))
        let release = coordinator.beginRemovingMedia([item.id])
        library.media = []; library.playlists = []; library.displays = []
        coordinator.reconcile(library)
        try await WallpaperMirrorTestSupport.waitUntil(description: "mirror draining") { gate.started }
        XCTAssertNotEqual(surface.state, .closed, "The mirror still owns the source window")
        gate.release()
        try await release.value
        XCTAssertEqual(surface.state, .closed)
        coordinator.shutdown()
        try await coordinator.waitForShutdown()
    }
}
