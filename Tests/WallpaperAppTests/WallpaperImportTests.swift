import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class WallpaperImportTests: XCTestCase {
    func testNewImportOwnsCopyIndependentOfOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let source = directory.appendingPathComponent("original.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: source)
        let model = AppModel(store: LibraryStore(url: directory.appendingPathComponent("library.json")))
        defer { model.shutdown() }
        model.importURLs([source])
        let deadline = ContinuousClock.now + .seconds(5)
        while model.importing {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Import did not complete") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.errorMessage)
        let item = try XCTUnwrap(model.library.media.first)
        XCTAssertNotEqual(item.url, source)
        XCTAssertEqual(item.url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Media")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: item.url), bytes)
        try await model.shutdownAndWait()
    }

    func testOpeningAndCancellingUnifiedImporterDoesNotModifyLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        let before = try Data(contentsOf: store.url)
        model.importFiles()
        XCTAssertTrue(model.showingImport)
        model.showingImport = false
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertTrue(model.library.media.isEmpty)
        XCTAssertNil(model.selectedMediaID)
        try await model.shutdownAndWait()
    }

    func testExplicitWebRootAndNestedEntryImportIntoSelectedPlaylist() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("网页 项目")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        try Data("<!doctype html><title>Selected entry</title>".utf8).write(to: root.appendingPathComponent("pages/场景.html"))
        try Data("<!doctype html><title>Not selected</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        let listID = try XCTUnwrap(model.library.playlists.first?.id)
        model.section = .playlist(listID)
        let project = WebProjectReference(root: root, entry: "pages/场景.html")
        let imported = await model.importWebProject(project)
        XCTAssertTrue(imported)
        let item = try XCTUnwrap(model.library.media.first)
        XCTAssertNotEqual(item.webProject?.root, project.root)
        XCTAssertEqual(item.webProject?.entry, project.entry)
        XCTAssertEqual(item.origin?.url, project.entryURL.standardizedFileURL)
        XCTAssertEqual(item.origin?.projectRoot, root.standardizedFileURL)
        XCTAssertNotNil(item.origin?.directoryIdentity)
        XCTAssertEqual(item.backend, .web)
        XCTAssertEqual(item.kind, .web)
        XCTAssertEqual(model.selectedMediaID, item.id)
        XCTAssertEqual(model.selectedEntryID, model.library.playlists[0].entries[0].id,
                       "An import into this playlist must select its actual entry")
        XCTAssertEqual(model.library.playlists[0].entries.map(\.mediaID), [item.id])
        XCTAssertEqual(model.library.playlists[0].entries[0].timing.mode, .seconds)
        XCTAssertEqual(try store.load(), model.library)
        let saved = model.library
        let repeated = await model.importWebProject(project)
        XCTAssertTrue(repeated)
        XCTAssertEqual(model.library, saved, "Reimport must not duplicate the same project")
        XCTAssertEqual(model.selectedEntryID, model.library.playlists[0].entries[0].id)
        try await model.shutdownAndWait()
    }

    func testInvalidWebEntryAndOutsideSymlinkKeepLibraryAndSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        try Data("<!doctype html>".utf8).write(to: root.appendingPathComponent("index.html"))
        let outside = directory.appendingPathComponent("outside.html")
        try Data("<!doctype html>".utf8).write(to: outside)
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        let imported = await model.importWebProject(WebProjectReference(root: root, entry: "index.html"))
        XCTAssertTrue(imported)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.html"), withDestinationURL: outside)
        let saved = model.library
        let selected = model.selectedMediaID
        for entry in ["missing.html", "../outside.html", "link.html"] {
            model.errorMessage = nil
            let imported = await model.importWebProject(WebProjectReference(root: root, entry: entry))
            XCTAssertFalse(imported)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.library, saved)
            XCTAssertEqual(model.selectedMediaID, selected)
            XCTAssertEqual(try store.load(), saved)
        }
        try await model.shutdownAndWait()
    }

    func testEntryPickerKeepsRelativeUnicodePathAndRejectsSiblingRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/wallpaper-project", isDirectory: true)
        XCTAssertEqual(try WebImportSelection.relativeEntry(root: root,
            selected: root.appendingPathComponent("子目录/入口 文件.html")), "子目录/入口 文件.html")
        XCTAssertThrowsError(try WebImportSelection.relativeEntry(root: root,
            selected: URL(fileURLWithPath: "/tmp/wallpaper-project-other/index.html")))
    }

    func testFailedImportSaveDoesNotSelectAnUnstoredWallpaper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        let initial = model.library
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = directory.appendingPathComponent("wallpaper.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)
        // A directory at the destination makes the real atomic save fail.
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        model.importURLs([image, directory.appendingPathComponent("missing.png")])
        let deadline = ContinuousClock.now + .seconds(5)
        while model.importing {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Import did not complete") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.errorMessage?.contains("library.json") == true, "A per-file failure must not hide the save failure")
        XCTAssertTrue(model.errorMessage?.contains("missing.png") == true)
        XCTAssertEqual(model.library, initial)
        XCTAssertNil(model.selectedMediaID, "Failed persistence must not select an item absent from the library")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Media").path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        try await model.shutdownAndWait()
    }

    func testRepeatedSourceAndManagedURLDoNotCreateAdditionalCopies() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let source = fixture.output.appendingPathComponent("new.png")
        try FileManager.default.copyItem(at: fixture.model.library.media[0].url, to: source)
        fixture.model.importURLs([source, source])
        try await waitForImport(fixture.model)
        let saved = fixture.model.library
        let item = try XCTUnwrap(saved.media.last)
        XCTAssertEqual(item.origin?.url, source)
        fixture.model.importURLs([source, item.url])
        try await waitForImport(fixture.model)
        XCTAssertEqual(fixture.model.library, saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.output.appendingPathComponent("Media").path).count, 1)
        try await fixture.model.shutdownAndWait()
    }

    func testLegacyReimportDoesNotMigrateOrCreateMediaDirectory() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let original = fixture.model.library
        fixture.model.importURLs([original.media[0].url])
        try await waitForImport(fixture.model)
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Media").path))
        try await fixture.model.shutdownAndWait()
    }

    private func waitForImport(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.importing {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Import did not complete") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
