import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

final class SystemWallpaperStoreTests: XCTestCase {
    func testSymbolicLinkUsesTheVersionOfTheActualMediaFile() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let alias = files.root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: files.item.url)
        let item = MediaItem(url: alias, kind: .image, width: 8, height: 6)
        let content = SystemWallpaperContent(item: item, fit: .fill, width: 8, height: 6)
        let store = files.store
        let before = try await store.key(for: content)
        try Data("replacement bytes at the link's unchanged destination".utf8).write(to: files.item.url, options: .atomic)
        let after = try await store.key(for: content)
        XCTAssertNotEqual(before, after, "The decoder follows the symlink, so its cache version must follow it too")
    }

    func testRealPixelsArePersistedAndReusedWithoutOverwriting() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let store = files.store
        let key = try await store.key(for: files.content)
        let missing = try await store.cachedImage(for: key)
        XCTAssertNil(missing)
        let url = try await store.save(SystemWallpaperFiles.image(), for: key)
        let original = try Data(contentsOf: url)
        let reused = try await store.save(SystemWallpaperFiles.image(red: 0), for: key)
        XCTAssertEqual(url, reused)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: original))
        XCTAssertEqual(bitmap.pixelsWide, 8)
        XCTAssertEqual(bitmap.pixelsHigh, 6)
        XCTAssertGreaterThan(try bitmap.sRGBColor(atX: 4, y: 3).redComponent, 0.9)
        let reopened = files.store
        let recovered = try await reopened.cachedImage(for: key)
        XCTAssertEqual(recovered, url, "Posters must survive the store and application lifetime")
    }

    func testMediaRevisionFitAndDimensionsChangePosterIdentity() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let store = files.store
        let original = try await store.key(for: files.content)
        let fit = try await store.key(for: .init(item: files.item, fit: .fit, width: 8, height: 6))
        let resized = try await store.key(for: .init(item: files.item, fit: .fill, width: 16, height: 12))
        XCTAssertNotEqual(original, fit)
        XCTAssertNotEqual(original, resized)
        try Data("new source content with another size".utf8).write(to: files.item.url)
        let changed = try await store.key(for: files.content)
        XCTAssertNotEqual(original, changed)
        do { _ = try await store.save(SystemWallpaperFiles.image(), for: original); XCTFail("Stale source key saved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("素材")) }
    }

    func testWebResourcesParticipateInTheSourceVersion() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let project = files.root.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let entry = project.appendingPathComponent("index.html"), css = project.appendingPathComponent("style.css")
        try Data("<html></html>".utf8).write(to: entry)
        try Data("body{}".utf8).write(to: css)
        let item = MediaItem(url: entry, kind: .web, width: 8, height: 6, backend: .web,
                            webProject: .init(root: project, entry: "index.html"))
        let content = SystemWallpaperContent(item: item, fit: .fill, width: 8, height: 6)
        let store = files.store
        let before = try await store.key(for: content)
        try Data("body{background:red}".utf8).write(to: css)
        let after = try await store.key(for: content)
        XCTAssertNotEqual(before, after)
    }

    func testWebFingerprintDoesNotTraverseExternalOrCyclicDirectoryLinks() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let project = files.root.appendingPathComponent("web")
        let outside = files.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let entry = project.appendingPathComponent("index.html")
        let externalResource = outside.appendingPathComponent("ignored.css")
        try Data("<html></html>".utf8).write(to: entry)
        try Data("external version 1".utf8).write(to: externalResource)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("external"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("cycle"), withDestinationURL: project)
        let item = MediaItem(url: entry, kind: .web, width: 8, height: 6, backend: .web,
                            webProject: .init(root: project, entry: "index.html"))
        let content = SystemWallpaperContent(item: item, fit: .fill, width: 8, height: 6)
        let store = files.store
        let before = try await store.key(for: content)
        try Data("external version 2 must not participate".utf8).write(to: externalResource, options: .atomic)
        let after = try await store.key(for: content)
        XCTAssertEqual(before, after)
    }

    func testCorruptedCachedImageIsReportedNotSilentlyRegenerated() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let store = files.store, key = try await store.key(for: files.content)
        let url = try await store.save(SystemWallpaperFiles.image(), for: key)
        try Data("corrupt".utf8).write(to: url)
        do { _ = try await store.cachedImage(for: key); XCTFail("Corrupt poster accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("底图")) }
        XCTAssertEqual(try Data(contentsOf: url), Data("corrupt".utf8))
    }

    func testWrongCaptureSizeAndUnwritableDirectoryFailExplicitly() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let store = files.store, key = try await store.key(for: files.content)
        do { _ = try await store.save(SystemWallpaperFiles.image(width: 4), for: key); XCTFail("Wrong size accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尺寸")) }
        let blocked = SystemWallpaperStore(directory: files.item.url)
        do { _ = try await blocked.save(SystemWallpaperFiles.image(), for: key); XCTFail("File used as directory") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        XCTAssertEqual(try Data(contentsOf: files.item.url), Data("source version 1".utf8))
    }

    func testInvalidGeometryAndMissingSourceAreNotGivenSubstituteImages() async throws {
        let files = try SystemWallpaperFiles()
        defer { try? files.remove() }
        let store = files.store
        do { _ = try await store.key(for: .init(item: files.item, fit: .fill, width: 0, height: 6)); XCTFail("Zero width") }
        catch { XCTAssertTrue(error.localizedDescription.contains("尺寸")) }
        try FileManager.default.removeItem(at: files.item.url)
        do { _ = try await store.key(for: files.content); XCTFail("Missing source") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
}
