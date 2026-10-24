import Foundation
import XCTest
@testable import WallpaperCore

final class EditorExchangeTests: XCTestCase {
    private let project = SceneProjectReference(root: URL(fileURLWithPath: "/tmp/场景 A"),
                                               entry: "nested/scene.json", representation: .loose)

    func testTwoWayLinksRoundTripWithoutLosingFileNames() throws {
        let descriptor = URL(fileURLWithPath: "/tmp/共享 索引.json")
        for link in [EditorLink.openEditor(project: nil, descriptor: nil),
                     .openEditor(project: project, descriptor: descriptor), .importScene(project)] {
            let url = try link.url()
            XCTAssertEqual(try EditorLink(url: url), link)
            XCTAssertNil(url.user); XCTAssertNil(url.password)
        }
    }

    func testMalformedOrUnversionedLinksAreRejected() throws {
        let invalid = [
            "dynamic-wallpaper-editor://open", "dynamic-wallpaper-editor://open?api=2",
            "dynamic-wallpaper-editor://open?api=1&api=1", "dynamic-wallpaper-editor://open?api=1&extra=1",
            "dynamic-wallpaper-editor://open/path?api=1", "dynamic-wallpaper-editor://open?api=1#x",
            "dynamic-wallpaper-editor://open?api=1&root=file:///tmp/a",
            "dynamic-wallpaper-editor://open?api=1&descriptor=https://example.com/project.json",
            "dynamic-wallpaper-editor://open?api=1&descriptor=file://remote/tmp/project.json",
            "dynamic-wallpaper://import-scene?api=1", "dynamic-wallpaper://unknown?api=1",
            "dynamic-wallpaper://import-scene?api=1&root=file:///tmp/a&entry=../x.json&representation=loose",
            "https://open?api=1",
        ]
        for value in invalid { XCTAssertThrowsError(try EditorLink(url: XCTUnwrap(URL(string: value))), value) }
        XCTAssertThrowsError(try EditorLink.openEditor(project: nil, descriptor: URL(string: "https://example.com")!).url())
    }

    func testDescriptorPreservesSceneOffersAndReadOnlyRendererReference() throws {
        let offer = EditorSceneOffer(id: UUID(), title: "Water", project: project)
        let renderer = SharedSceneRenderer(version: "3.0.0", module: URL(fileURLWithPath: "/tmp/runtime.mjs"),
                                           sha256: String(repeating: "a", count: 64))
        let descriptor = try EditorExchange(hostBundleIdentifier: "local.dynamicwallpaper.app", scenes: [offer], renderer: renderer)
        XCTAssertEqual(try EditorExchange(data: descriptor.encoded()), descriptor)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: descriptor.encoded()) as? [String: Any])
        for patch: [String: Any] in [["version": 2], ["version": true], ["extra": 1], ["scenes": true],
                                    ["renderer": false], ["hostBundleIdentifier": ""], ["scenes": ["bad"]]] {
            let invalid = value.merging(patch) { _, replacement in replacement }
            XCTAssertThrowsError(try EditorExchange(data: JSONSerialization.data(withJSONObject: invalid)), "\(patch)")
        }
        value["scenes"] = [value["scenes"] as! [Any], value["scenes"] as! [Any]].flatMap { $0 }
        XCTAssertThrowsError(try EditorExchange(data: JSONSerialization.data(withJSONObject: value)), "Duplicate scene IDs are ambiguous")
        XCTAssertThrowsError(try EditorExchange(hostBundleIdentifier: "local.app", scenes: [offer],
            renderer: SharedSceneRenderer(version: "3.0.0", module: URL(string: "https://example.com/renderer.mjs")!, sha256: renderer.sha256)))
    }
}
