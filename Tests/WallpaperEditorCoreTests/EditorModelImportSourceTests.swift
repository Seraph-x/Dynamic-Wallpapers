import Foundation
import XCTest
@testable import WallpaperEditorCore

final class EditorModelImportSourceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func write(_ path: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url); return url
    }
    private func source(_ json: String) throws -> EditorModelImportSource {
        try EditorModelImportSource(url: write("model.gltf", Data(json.utf8)))
    }
    private func glb(_ chunks: [(UInt32, Data)], version: UInt32 = 2) -> Data {
        func word(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        var body = Data()
        for (type, data) in chunks { body += word(UInt32(data.count)); body += word(type); body += data }
        return word(0x46546c67) + word(version) + word(UInt32(12 + body.count)) + body
    }
    private func jsonChunk(_ json: String) -> Data {
        var result = Data(json.utf8)
        while result.count % 4 != 0 { result.append(0x20) }
        return result
    }

    func testReadsOnlySelectedEntryAndExplicitReferencesAndOwnsBytes() throws {
        let bytes = Data([0, 1, 255])
        try write("buffers/data.bin", bytes); try write("private.txt", Data("unrelated".utf8))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("unrelated-link"), withDestinationURL: root)
        let json = #"{"asset":{"version":"2.0"},"buffers":[{"uri":"buffers/data.bin","byteLength":3}],"extras":{"uri":"private.txt"}}"#
        let result = try source(json)
        XCTAssertEqual(result.entry, "model.gltf")
        XCTAssertEqual(result.files, ["model.gltf": Data(json.utf8), "buffers/data.bin": bytes])
        try write("buffers/data.bin", Data([9]))
        XCTAssertEqual(result.files["buffers/data.bin"], bytes)
    }
    func testCommandContainsOnlySortedRelativePathsAndCanonicalBase64() throws {
        try write("z.bin", Data([255])); try write("a.png", Data([0, 1]))
        let result = try source(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"z.bin","byteLength":1}],"images":[{"uri":"a.png"}]}"#)
        let command = result.commandSource
        XCTAssertEqual(Set(command.keys), ["entry", "files"])
        XCTAssertEqual(command["entry"] as? String, "model.gltf")
        let files = try XCTUnwrap(command["files"] as? [[String: String]])
        XCTAssertEqual(files.map { $0["path"]! }, ["a.png", "model.gltf", "z.bin"])
        for file in files {
            XCTAssertEqual(Set(file.keys), ["path", "data"])
            XCTAssertEqual(file["data"], result.files[file["path"]!]!.base64EncodedString())
        }
    }
    func testDataURIsStayEmbeddedAndUTF8PercentPathsResolveOnce() throws {
        try write("纹理/a b.png", Data([4]))
        let result = try source(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"data:application/octet-stream;base64,AA==","byteLength":1}],"images":[{"uri":"%E7%BA%B9%E7%90%86/a%20b.png"}]}"#)
        XCTAssertEqual(Set(result.files.keys), ["model.gltf", "纹理/a b.png"])
    }
    func testPercentAndDoubleEncodedLiteralPathsAreDecodedExactlyOnce() throws {
        try write("100%.png", Data([1])); try write("%2e%2e/data.bin", Data([2]))
        let result = try source(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"%252e%252e/data.bin","byteLength":1}],"images":[{"uri":"100%25.png"}]}"#)
        XCTAssertEqual(result.files["100%.png"], Data([1]))
        XCTAssertEqual(result.files["%2e%2e/data.bin"], Data([2]))
    }
    func testGLBPreservesAllChunksAndCollectsExternalImages() throws {
        try write("image.png", Data([7]))
        let json = #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":4}],"images":[{"uri":"image.png"}]}"#
        let bytes = glb([(0x4e4f534a, jsonChunk(json)), (0x004e4942, Data([1, 2, 3, 4])), (0x12345678, Data([9, 8, 7, 6]))])
        let result = try EditorModelImportSource(url: write("model.glb", bytes))
        XCTAssertEqual(result.files, ["model.glb": bytes, "image.png": Data([7])])
    }
    func testRejectsInvalidGLBHeadersLengthsOrderAlignmentAndJSON() throws {
        let json = jsonChunk(#"{"asset":{"version":"2.0"}}"#)
        let valid = glb([(0x4e4f534a, json)])
        var trailing = valid; trailing.append(0)
        var wrongLength = valid; wrongLength[8] = 12
        let bad = [Data(), Data(valid.prefix(11)), trailing, wrongLength,
            glb([(0x4e4f534a, json)], version: 1), glb([(0x004e4942, Data([0, 0, 0, 0])), (0x4e4f534a, json)]),
            glb([(0x4e4f534a, json), (0x4e4f534a, json)]), glb([(0x4e4f534a, json), (0x12345678, Data()), (0x004e4942, Data())]),
            glb([(0x4e4f534a, json), (0x004e4942, Data()), (0x004e4942, Data())]),
            glb([(0x4e4f534a, Data("{} ".utf8))]), glb([(0x4e4f534a, Data("nope".utf8))])]
        for bytes in bad { XCTAssertThrowsError(try EditorModelImportSource(url: write("bad.glb", bytes))) }
    }
    func testRejectsUnsafeURIsAndMissingFilesWithoutBasenameLookup() throws {
        try write("missing.bin", Data([0]))
        let uris = ["../missing.bin", "%2e%2e/missing.bin", "%252e%252e/missing.bin", "/missing.bin", "//host/a", "https://host/a",
            "file:missing.bin", "a?x", "a#x", "a\\b", "a\u{0}b", "a%", "a%2", "a%GG", "a%00b", "a%2fb", "a%5cb", "a//b", "./missing.bin", "nested/missing.bin"]
        for uri in uris {
            let json = try JSONSerialization.data(withJSONObject: ["asset": ["version": "2.0"], "buffers": [["uri": uri, "byteLength": 1]]])
            XCTAssertThrowsError(try EditorModelImportSource(url: write("model.gltf", json)), uri)
        }
    }
    func testRejectsRawURIControlCharacters() throws {
        for uri in ["line\nbreak.png", "tab\tname.png", "control\u{1f}.png"] {
            try write(uri, Data([0]))
            let json = try JSONSerialization.data(withJSONObject: ["asset": ["version": "2.0"], "images": [["uri": uri]]])
            XCTAssertThrowsError(try EditorModelImportSource(url: write("model.gltf", json)), uri.debugDescription)
        }
    }
    func testRejectsDecodedURIControlCharactersAndRawDEL() throws {
        for (uri, path) in [("line%0abreak.png", "line\nbreak.png"), ("tab%09name.png", "tab\tname.png"),
                            ("control%1f.png", "control\u{1f}.png"), ("delete%7f.png", "delete\u{7f}.png"),
                            ("delete\u{7f}.png", "delete\u{7f}.png")] {
            try write(path, Data([0]))
            let json = try JSONSerialization.data(withJSONObject: ["asset": ["version": "2.0"], "images": [["uri": uri]]])
            XCTAssertThrowsError(try EditorModelImportSource(url: write("model.gltf", json)), uri.debugDescription)
        }
    }
    func testRejectsControlCharactersInSelectedEntryName() throws {
        for name in ["line\nname.gltf", "tab\tname.glb", "control\u{1f}.gltf", "delete\u{7f}.gltf"] {
            let json = jsonChunk(#"{"asset":{"version":"2.0"}}"#)
            let data = name.hasSuffix(".glb") ? glb([(0x4e4f534a, json)]) : json
            XCTAssertThrowsError(try EditorModelImportSource(url: write(name, data)), name.debugDescription)
        }
    }
    func testRejectsMalformedSourceMetadataBeforeReferenceReads() throws {
        let invalid = ["[]", "{", #"{"asset":{"version":"1.0"}}"#, #"{"asset":{"version":"2.0"},"buffers":{}}"#,
            #"{"asset":{"version":"2.0"},"buffers":[{"uri":7,"byteLength":1}]}"#,
            #"{"asset":{"version":"2.0"},"buffers":[{"uri":"missing.bin","byteLength":true}]}"#,
            #"{"asset":{"version":"2.0"},"buffers":[{"byteLength":1}]}"#,
            #"{"asset":{"version":"2.0"},"images":[{"uri":null}]}"#,
            #"{"asset":{"version":"2.0"},"images":[{"uri":"missing.png","bufferView":0}]}"#,
            #"{"asset":{"version":"2.0"},"images":[{"bufferView":-1,"mimeType":"image/png"}]}"#]
        for json in invalid { XCTAssertThrowsError(try source(json), json) }
        do {
            _ = try source(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"missing.bin","byteLength":1}],"images":[{"uri":42}]}"#)
            XCTFail("Invalid later metadata was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("metadata"), error.localizedDescription) }
    }
    func testRejectsRootFileAndDirectorySymlinks() throws {
        let json = Data(#"{"asset":{"version":"2.0"}}"#.utf8)
        try write("actual/model.gltf", json)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root.appendingPathComponent("actual"))
        XCTAssertThrowsError(try EditorModelImportSource(url: root.appendingPathComponent("linked/model.gltf")))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("selected.gltf"), withDestinationURL: root.appendingPathComponent("actual/model.gltf"))
        XCTAssertThrowsError(try EditorModelImportSource(url: root.appendingPathComponent("selected.gltf")))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("nested"), withDestinationURL: root.appendingPathComponent("actual"))
        XCTAssertThrowsError(try source(#"{"asset":{"version":"2.0"},"images":[{"uri":"nested/model.gltf"}]}"#))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("texture.png"), withDestinationURL: root.appendingPathComponent("actual/model.gltf"))
        XCTAssertThrowsError(try source(#"{"asset":{"version":"2.0"},"images":[{"uri":"texture.png"}]}"#))
    }
    func testRejectsCaseAndUnicodeFileOrDirectoryAliases() throws {
        try write("Textures/Image.png", Data([0]))
        XCTAssertThrowsError(try source(#"{"asset":{"version":"2.0"},"images":[{"uri":"textures/Image.png"}]}"#))
        XCTAssertThrowsError(try source(#"{"asset":{"version":"2.0"},"images":[{"uri":"Textures/image.png"}]}"#))
        try write("café.png", Data([1]))
        // APFS may store decomposed names: matching canonical spelling is valid, but two source aliases are not.
        let object: [String: Any] = ["asset": ["version": "2.0"], "images": [["uri": "café.png"], ["uri": "cafe\u{301}.png"]]]
        XCTAssertThrowsError(try EditorModelImportSource(url: write("model.gltf", JSONSerialization.data(withJSONObject: object))))
    }
    func testRejectsNonFileURLsAndUnsupportedEntries() throws {
        XCTAssertThrowsError(try EditorModelImportSource(url: URL(string: "https://example.invalid/model.gltf")!))
        XCTAssertThrowsError(try EditorModelImportSource(url: write("model.json", Data(#"{"asset":{"version":"2.0"}}"#.utf8))))
    }
    func testReadOnlyScopePinsOriginalRootAcrossPathReplacementWithoutWritingLock() throws {
        try write("original.bin", Data([1]))
        let moved = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: moved) }
        let reader = EditorProjectFiles(root: root)
        try reader.withReadOnlyScope { scoped in
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try write("original.bin", Data([2]))
            XCTAssertEqual(try scoped.read("original.bin"), Data([1]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(".workspace-lock").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".workspace-lock").path))
        }
        XCTAssertEqual(try reader.read("original.bin"), Data([2]))
    }
}
