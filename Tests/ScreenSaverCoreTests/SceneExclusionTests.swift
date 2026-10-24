import XCTest
import WallpaperCore
import ScreenSaverCore

final class SceneExclusionTests: XCTestCase {
    func testSceneHasExplicitExclusionAndCannotPublishAlone() throws {
        let scene = SceneProjectReference(root: URL(fileURLWithPath: "/scene"), entry: "scene.pkg", representation: .package)
        let item = MediaItem(url: scene.entryURL, kind: .scene, width: 640, height: 360, backend: .scene, sceneProject: scene)
        var library = Library.empty
        library.media = [item]
        let projection = try ScreenSaverProjection(library: library, source: .media(item.id))
        XCTAssertTrue(projection.entries.isEmpty)
        XCTAssertEqual(projection.exclusions.first?.signature.reason, .sceneContent)
        let consent = ScreenSaverConsent(acknowledging: projection)
        XCTAssertEqual(try JSONDecoder().decode(ScreenSaverConsent.self, from: JSONEncoder().encode(consent)), consent)
        XCTAssertThrowsError(try projection.validateForPublication(consent: consent)) {
            XCTAssertEqual($0 as? ScreenSaverProjectionError, .noSupportedMedia)
        }
    }
}
