import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor final class EditorHandoffTests: XCTestCase {
    func testImportSelectsOwnedLibraryCopyWithoutAddingToPlaylistOrApplyingWallpaper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let root = directory.appendingPathComponent("Editor export")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data(#"{"type":"scene","file":"scene.json","title":"From Editor"}"#.utf8).write(to:root.appendingPathComponent("project.json"))
        try Data(#"{"objects":[]}"#.utf8).write(to:root.appendingPathComponent("scene.json"))
        let store = LibraryStore(url:directory.appendingPathComponent("library.json")); try store.save(.empty)
        let model = AppModel(store:store); defer { model.shutdown() }
        model.section = .playlist(try XCTUnwrap(model.library.playlists.first?.id))
        let before = model.library.displays, identity = model.desktopIdentity
        let project = SceneProjectReference(root:root,entry:"scene.json",representation:.loose)
        let success = try await model.receiveEditorLink(EditorLink.importScene(project).url())
        XCTAssertTrue(success); XCTAssertEqual(model.library.media.count,1)
        XCTAssertTrue(model.library.playlists.allSatisfy(\.entries.isEmpty)); XCTAssertEqual(model.section,.library)
        XCTAssertEqual(model.selectedMediaID,model.library.media.first?.id)
        XCTAssertEqual(model.library.displays,before); XCTAssertEqual(model.desktopIdentity,identity)
        XCTAssertNotEqual(model.library.media.first?.sceneProject?.root,root)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("scene.json")),Data(#"{"objects":[]}"#.utf8))
        try await model.shutdownAndWait()
    }
    func testUnknownEditorRequestCannotChangeTheLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = LibraryStore(url:directory.appendingPathComponent("library.json")); try store.save(.empty)
        let model = AppModel(store:store); defer { model.shutdown() }
        let before = model.library
        do { _ = try await model.receiveEditorLink(URL(string:"dynamic-wallpaper://import-scene?api=2")!); XCTFail() } catch {}
        XCTAssertEqual(model.library,before)
        try await model.shutdownAndWait()
    }
}
