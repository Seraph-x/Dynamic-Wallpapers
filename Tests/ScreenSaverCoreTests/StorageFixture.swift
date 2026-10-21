import XCTest
import CryptoKit
import CoreGraphics
import ImageIO
import Foundation
import WallpaperCore
import ScreenSaverCore

struct StorageFixture {
    let projection: ScreenSaverProjection
    let settings: ScreenSaverSettings
    let bytes: Data
    let file: ScreenSaverMediaFile

    init() throws {
        let data = NSMutableData()
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        bytes = data as Data
        let item = MediaItem(url: URL(fileURLWithPath: "/source-only/fixture.png"), kind: .image, width: 1, height: 1)
        var library = Library()
        library.media = [item]
        projection = try ScreenSaverProjection(library: library, source: .media(item.id))
        settings = ScreenSaverSettings(source: projection.source)
        file = try ScreenSaverMediaFile(media: item, relativePath: "media/\(item.id.uuidString).png",
            byteCount: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    func manifest(id: UUID, files: [ScreenSaverMediaFile]? = nil) throws -> ScreenSaverManifest {
        try ScreenSaverManifest(generationID: id, projection: projection, settings: settings, files: files ?? [file])
    }

    func stage(in store: ScreenSaverSnapshotStore) async throws -> ScreenSaverStagingGeneration {
        let stage = try await store.beginPublication()
        do {
            try bytes.write(to: stage.directory.appendingPathComponent(file.relativePath), options: .withoutOverwriting)
            return stage
        } catch {
            do { try await store.abort(stage) }
            catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
    }

    func publish(in store: ScreenSaverSnapshotStore) async throws -> ScreenSaverCurrentPointer {
        let stage = try await stage(in: store)
        return try await store.commit(stage, manifest: manifest(id: stage.id), settingsRevision: UUID())
    }
}

class SnapshotTestCase: XCTestCase {
    var directory: URL!
    var store: ScreenSaverSnapshotStore!
    var fixture: StorageFixture!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("screensaver-store-\(UUID())")
        store = try ScreenSaverSnapshotStore(root: directory)
        _ = try await store.initialize()
        fixture = try StorageFixture()
    }

    override func tearDown() async throws {
        fixture = nil
        store = nil
        try FileManager.default.removeItem(at: directory)
    }
}
