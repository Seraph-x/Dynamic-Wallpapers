@testable import WallpaperNative
import AppKit
import UniformTypeIdentifiers
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ExtendedRoutingTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/dependencies/mpv/fixtures")
    }

    func testImportPickerAndRealImportPersistAllThreeContainersInSelectedList() async throws {
        for ext in ["mkv", "webm", "avi"] {
            XCTAssertTrue(MediaProbe.fileExtensions.contains(ext))
            XCTAssertNotNil(UTType(filenameExtension: ext))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let store = LibraryStore(url: directory.appendingPathComponent("library-extended.json"))
        let model = AppModel(store: store)
        model.addPlaylist()
        let listID = try XCTUnwrap(model.selectedPlaylist?.id)
        let urls = ["h264-aac.mkv", "vp9-opus.webm", "mpeg4-mp3.avi"].map { fixtures.appendingPathComponent($0) }
        model.importURLs(urls)
        try await waitUntil { !model.importing }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.library.media.map(\.backend), [.extended, .extended, .extended])
        XCTAssertEqual(model.library.playlists.first { $0.id == listID }?.entries.map(\.mediaID), model.library.media.map(\.id))
        XCTAssertEqual(try store.load(), model.library)
        let corrupt = directory.appendingPathComponent("broken.mkv")
        try Data("broken".utf8).write(to: corrupt)
        let saved = try Data(contentsOf: store.url)
        model.importURLs([corrupt])
        try await waitUntil { !model.importing }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: store.url), saved)
        try await model.shutdownAndWait()
    }

    func testFactoryRoutesExtendedVideoAndPreservesNativeBackend() async throws {
        let item = MediaItem(url: fixtures.appendingPathComponent("h264-aac.mkv"), kind: .video,
                             width: 320, height: 180, duration: 2, backend: .extended)
        let surface = try SurfaceFactory().makeSurface(item: item, size: CGSize(width: 96, height: 64), fit: .fit)
        XCTAssertTrue(surface is MPVSurface)
        try await surface.prepare(item: item, scale: 1, fit: .fit)
        XCTAssertEqual(surface.state, .ready)
        try await surface.close()
        let native = MediaItem(url: URL(fileURLWithPath: "/unused.png"), kind: .image, width: 1, height: 1)
        let original = try SurfaceFactory().makeSurface(item: native, size: CGSize(width: 64, height: 64), fit: .fit)
        XCTAssertTrue(original is MediaSurface)
        try await original.close()
    }

    func testThumbnailViewDecodesRealExtendedPixels() async throws {
        let item = try await ExtendedMediaProbe.inspect(fixtures.appendingPathComponent("vp9-opus.webm"))
        let loaded = try await MediaThumbnail.load(item)
        let thumbnail = try XCTUnwrap(loaded)
        let image = try XCTUnwrap(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertLessThanOrEqual(image.width, 480)
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(bytes).count, 16, "Thumbnail must contain actual decoded colour pixels")
    }

    func testRealPreviewUsesMPVAndClosesThroughSharedLifetime() async throws {
        let item = try await ExtendedMediaProbe.inspect(fixtures.appendingPathComponent("vp9-opus.webm"))
        let lifetime = PreviewLifetime()
        let coordinator = LivePreview.Coordinator(lifetime: lifetime, onError: { XCTFail("\($0)") })
        var actualDecoder: String?
        coordinator.onDecoderChange = { actualDecoder = $0 }
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 160, height: 100))
        coordinator.start(item: item, host: host)
        await coordinator.task?.value
        let surface = try XCTUnwrap(coordinator.surface as? MPVSurface)
        XCTAssertEqual(surface.state, .playing)
        XCTAssertTrue(try surface.audioIsMuted())
        XCTAssertNotNil(surface.currentImage)
        XCTAssertEqual(actualDecoder, surface.metadata?.hardwareDecoder)
        XCTAssertNotNil(actualDecoder)
        coordinator.close()
        try await coordinator.closeTask?.value
        XCTAssertEqual(surface.state, .closed)
        XCTAssertEqual(lifetime.activeSurfaceCount, 0)
    }

    func testDesktopSwitchesNativeAndExtendedAndPreservesFrameOnFailure() async throws {
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main))
        window.updateGeometry(frame: CGRect(x: 20, y: 20, width: 160, height: 100), scale: 1)
        defer { window.shutdown() }
        let url = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail("\(error)") } }
        let native = try await MediaProbe.inspect(url)
        try await window.prepare(item: native, fit: .fit, entry: PlaylistEntry(mediaID: native.id))
        let first = await window.transition(duration: 0, paused: false)
        XCTAssertTrue(first.didDisplay)
        let extended = try await MediaProbe.inspect(fixtures.appendingPathComponent("mpeg4-mp3.avi"))
        try await window.prepare(item: extended, fit: .fill, entry: PlaylistEntry(mediaID: extended.id))
        XCTAssertEqual(window.activeSurfaceCount, 2)
        let second = await window.transition(duration: 0.02, paused: false)
        XCTAssertTrue(second.didDisplay)
        XCTAssertEqual(window.activeSurfaceCount, 1)
        let surface = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? MPVSurface }.first)
        XCTAssertEqual(surface.state, .playing)
        XCTAssertTrue(try surface.audioIsMuted())
        let missing = MediaItem(url: url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mkv"),
                                kind: .video, width: 1, height: 1, backend: .extended)
        do {
            try await window.prepare(item: missing, fit: .fit, entry: PlaylistEntry(mediaID: missing.id))
            XCTFail("Missing extended media must fail")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(surface.state, .playing)
        XCTAssertEqual(window.activeSurfaceCount, 1)
        try await window.prepare(item: native, fit: .fit, entry: PlaylistEntry(mediaID: native.id))
        let third = await window.transition(duration: 0.02, paused: false)
        XCTAssertTrue(third.didDisplay)
        XCTAssertEqual(surface.state, .closed)
        window.shutdown()
        try await window.waitForClosing()
        XCTAssertEqual(window.activeSurfaceCount, 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("扩展导入测试超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
