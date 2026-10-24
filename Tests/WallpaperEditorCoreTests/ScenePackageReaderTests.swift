import Foundation
import XCTest
@testable import WallpaperEditorCore

final class ScenePackageReaderTests: XCTestCase {
    static func package(_ entries: [(String, Data)]) -> Data {
        var data = Data()
        func number(_ value: Int) { var word = UInt32(value).littleEndian; data.append(Data(bytes: &word, count: 4)) }
        number(8); data.append(Data("PKGV0012".utf8)); number(entries.count)
        var offset = 0
        for (name, bytes) in entries { number(name.utf8.count); data.append(Data(name.utf8)); number(offset); number(bytes.count); offset += bytes.count }
        for (_, bytes) in entries { data.append(bytes) }
        return data
    }
    func testReadsActualContainerAndUnicodeNames() throws {
        let bytes = Self.package([("scene.json", Data("{}".utf8)), ("图片/云.png", Data([1, 2, 3]))])
        let package = try ScenePackageReader(data: bytes)
        XCTAssertEqual(package.paths, ["scene.json", "图片/云.png"])
        XCTAssertEqual(try package.read("图片/云.png"), Data([1, 2, 3]))
        XCTAssertThrowsError(try package.read("missing"))
    }
    func testRejectsUnsafeAmbiguousTruncatedAndOverlappingContainers() throws {
        let valid = Self.package([("scene.json", Data("{}".utf8)), ("a", Data([1, 2]))])
        for end in 0..<valid.count { XCTAssertThrowsError(try ScenePackageReader(data: valid.prefix(end)), "\(end)") }
        for names in [["scene.json", "scene.json"], ["scene.json", "SCENE.json"], ["../scene.json"], ["a/../scene.json"], ["/scene.json"], ["a\\scene.json"], ["a", "a/b"], ["a/"], ["scene.json", "Scene.JSON/x"]] {
            XCTAssertThrowsError(try ScenePackageReader(data: Self.package(names.map { ($0, Data([1])) })), "\(names)")
        }
        var overlap = valid
        // Second entry offset follows its one-byte name at byte 43.
        overlap.replaceSubrange(43..<47, with: [0, 0, 0, 0])
        XCTAssertThrowsError(try ScenePackageReader(data: overlap))
        var version = valid; version[10] = 0x39
        XCTAssertThrowsError(try ScenePackageReader(data: version))
    }
}
