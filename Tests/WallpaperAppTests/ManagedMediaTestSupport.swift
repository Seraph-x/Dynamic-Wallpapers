import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ManagedReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var started: Bool { continuation != nil }
    func wait() async { calls += 1; await withCheckedContinuation { continuation = $0 } }
    func release() { let pending = continuation; continuation = nil; pending?.resume() }
}

@MainActor
final class ManagedLifecycleFixture {
    let directory: URL
    let model: AppModel

    init(importProbe: ManagedMediaImport.Probe? = nil, inspection: InspectorMediaModel? = nil,
         thumbnails: ThumbnailLifetime? = nil, transcoding: TranscodeModel? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let importer = ManagedMediaImport(files: ManagedMediaStore(directory: directory.appendingPathComponent("Media")), probe: importProbe)
        model = AppModel(store: store, transcoding: transcoding, inspectorMedia: inspection,
                         managedImport: importer, thumbnails: thumbnails)
    }

    func image(_ name: String) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let url = directory.appendingPathComponent(name)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func importImage() async throws -> MediaItem { try await importURL(image("source.png")) }

    func importURL(_ url: URL) async throws -> MediaItem {
        model.importURLs([url])
        let deadline = ContinuousClock.now + .seconds(5)
        while model.importing {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Import timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(model.failure)
        return try XCTUnwrap(model.library.media.last)
    }

    func close() async throws {
        try await model.shutdownAndWait()
        try FileManager.default.removeItem(at: directory)
    }
}
