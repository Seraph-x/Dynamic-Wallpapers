import XCTest
import Darwin
import WallpaperCore
@testable import WallpaperApp

final class WebProjectTests: XCTestCase {
    var directory: URL!
    var root: URL { directory.appendingPathComponent("project", isDirectory: true) }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<html><canvas></canvas></html>".utf8).write(to: root.appendingPathComponent("index.html"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testInspectsLocalProjectAndReadsRelativeModule() throws {
        let reference = WebProjectReference(root: root, entry: "index.html")
        let item = try WebProjectProbe.inspect(reference)
        XCTAssertEqual(item.backend, .web)
        XCTAssertEqual(item.kind, .web)
        XCTAssertEqual(item.webProject, reference)
        XCTAssertNil(item.duration)
        let script = Data("export const value = 42".utf8)
        try script.write(to: root.appendingPathComponent("module.js"))
        let resource = try WebProjectProbe.readResource(project: reference, relativePath: "module.js")
        XCTAssertEqual(resource.data, script)
        XCTAssertEqual(resource.mimeType, "text/javascript")
    }

    func testMissingRootEntryAndDirectoryInsteadOfEntryFail() throws {
        XCTAssertThrowsError(try WebProjectProbe.inspect(WebProjectReference(root: directory.appendingPathComponent("missing"), entry: "index.html")))
        XCTAssertThrowsError(try WebProjectProbe.inspect(WebProjectReference(root: root, entry: "missing.html")))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.html"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try WebProjectProbe.inspect(WebProjectReference(root: root, entry: "folder.html")))
    }

    func testRejectsOutsideSymlinkForEntryAndResource() throws {
        let external = directory.appendingPathComponent("outside.html")
        try Data("outside".utf8).write(to: external)
        let link = root.appendingPathComponent("link.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertThrowsError(try WebProjectProbe.inspect(WebProjectReference(root: root, entry: "link.html")))
        XCTAssertThrowsError(try WebProjectProbe.readResource(project: WebProjectReference(root: root, entry: "index.html"), relativePath: "link.html"))
    }

    func testAllowsSymlinkWithinProjectAndRejectsChangedLinkOnLaterRead() throws {
        let target = root.appendingPathComponent("module.js")
        let link = root.appendingPathComponent("link.js")
        try Data("inside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let reference = WebProjectReference(root: root, entry: "index.html")
        XCTAssertEqual(try WebProjectProbe.readResource(project: reference, relativePath: "link.js").data, Data("inside".utf8))
        try FileManager.default.removeItem(at: link)
        let external = directory.appendingPathComponent("outside.js")
        try Data("outside".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        XCTAssertThrowsError(try WebProjectProbe.readResource(project: reference, relativePath: "link.js"))
    }

    func testRejectsTraversalAndPrefixSiblingButAllowsUnicodeSpace() throws {
        let reference = WebProjectReference(root: root, entry: "index.html")
        for path in ["../outside", "/etc/passwd", "a/../../outside", "", "a\0b"] {
            XCTAssertThrowsError(try WebProjectProbe.readResource(project: reference, relativePath: path))
        }
        try Data("module".utf8).write(to: root.appendingPathComponent("中文 file.js"))
        XCTAssertEqual(try WebProjectProbe.readResource(project: reference, relativePath: "中文 file.js").data, Data("module".utf8))
        let sibling = directory.appendingPathComponent("project-other", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        try Data("outside".utf8).write(to: sibling.appendingPathComponent("asset.js"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sibling"), withDestinationURL: sibling)
        XCTAssertThrowsError(try WebProjectProbe.readResource(project: reference, relativePath: "sibling/asset.js"))
    }

    func testNamedPipeIsRejectedWithoutWaitingForWriter() throws {
        let pipe = root.appendingPathComponent("pipe.js")
        XCTAssertEqual(pipe.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) }, 0)
        let reference = WebProjectReference(root: root, entry: "index.html")
        XCTAssertThrowsError(try WebProjectProbe.readResource(project: reference, relativePath: "pipe.js")) { error in
            XCTAssertTrue(error.localizedDescription.contains("不是普通文件"))
        }
    }
}
