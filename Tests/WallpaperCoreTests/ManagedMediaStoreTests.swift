import Darwin
import XCTest
@testable import WallpaperCore

final class ManagedMediaStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ManagedMediaStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ManagedMediaStore(directory: directory.appendingPathComponent("Media"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testStagedCopyCommitsIndependentlyAndRoundTripsItsOrigin() async throws {
        let source = try file("source.png", bytes: "original bytes")
        let copy = try await store.stage(source: .file(source))
        XCTAssertEqual(try Data(contentsOf: copy.stagedURL), Data("original bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path))
        try await store.commit(copy)
        let item = copy.item(from: MediaItem(url: copy.stagedURL, kind: .image, width: 2, height: 2))
        XCTAssertEqual(item.origin?.url, source)
        XCTAssertEqual(item.url.deletingLastPathComponent().lastPathComponent, item.id.uuidString)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item)), item)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: item.url), Data("original bytes".utf8))
        try await store.remove(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        try await store.remove(item) // A completed unlink with an unacknowledged JSON queue must be retryable.
    }

    func testSameNamesDoNotOverwriteAndDiscardCleansBothPhases() async throws {
        let first = try await store.stage(source: .file(file("a/same.png", bytes: "one")))
        let second = try await store.stage(source: .file(file("b/same.png", bytes: "two")))
        XCTAssertNotEqual(first.url, second.url)
        try await store.commit(first)
        try await store.commit(second)
        XCTAssertEqual(try Data(contentsOf: first.url), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second.url), Data("two".utf8))
        try await store.discard(first)
        try await store.discard(second)
        let third = try await store.stage(source: .file(file("c.png", bytes: "three")))
        try await store.discard(third)
        XCTAssertEqual(try contents(), [])
    }

    func testSingleFileSymlinkBecomesAnIndependentRegularFile() async throws {
        let original = try file("actual.dat", bytes: "pixels")
        let link = directory.appendingPathComponent("selected.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let copy = try await store.stage(source: .file(link))
        try await store.commit(copy)
        XCTAssertEqual(copy.url.lastPathComponent, "selected.png")
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: copy.url.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(try Data(contentsOf: copy.url), Data("pixels".utf8))
    }

    func testWholeProjectMaterializesInternalFileAndDirectoryLinks() async throws {
        let root = directory.appendingPathComponent("project")
        _ = try file("project/pages/入口.html", bytes: "<html></html>")
        _ = try file("project/assets/data.txt", bytes: "resource")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked-assets").path,
                                                   withDestinationPath: "assets")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias.txt").path,
                                                   withDestinationPath: "assets/data.txt")
        let copy = try await store.stage(source: .web(WebProjectReference(root: root, entry: "pages/入口.html")))
        try await store.commit(copy)
        let project = try XCTUnwrap(copy.webProject)
        XCTAssertEqual(project.entry, "pages/入口.html")
        try FileManager.default.removeItem(at: root)
        for path in ["assets/data.txt", "linked-assets/data.txt", "alias.txt"] {
            XCTAssertEqual(try Data(contentsOf: project.root.appendingPathComponent(path)), Data("resource".utf8))
        }
    }

    func testProjectRejectsExternalLinksCyclesAndSpecialFilesWithoutResidue() async throws {
        let root = directory.appendingPathComponent("project")
        _ = try file("project/index.html", bytes: "<html></html>")
        let outside = try file("outside.txt", bytes: "private")
        let link = root.appendingPathComponent("link")
        for destination in [outside.path, root.path, link.path] {
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
            await assertFailure { _ = try await self.store.stage(source: .web(WebProjectReference(root: root, entry: "index.html"))) }
            XCTAssertEqual(try contents(), [])
            try FileManager.default.removeItem(at: link)
        }
        XCTAssertEqual(mkfifo(link.path, 0o600), 0)
        await assertFailure { _ = try await self.store.stage(source: .web(WebProjectReference(root: root, entry: "index.html"))) }
        XCTAssertEqual(try contents(), [])
    }

    func testLegacyAndForgedExternalItemCannotDeleteSource() async throws {
        let source = try file("source.png", bytes: "keep")
        try await store.remove(MediaItem(url: source, kind: .image, width: 1, height: 1))
        let forged = MediaItem(url: source, kind: .image, width: 1, height: 1, origin: MediaOrigin(url: source))
        await assertFailure { try await self.store.remove(forged) }
        XCTAssertEqual(try Data(contentsOf: source), Data("keep".utf8))
    }

    func testRemovalRejectsReplacedItemAndMediaRootSymlinks() async throws {
        let source = try file("source.png", bytes: "keep")
        let copy = try await store.stage(source: .file(source))
        try await store.commit(copy)
        let item = copy.item(from: MediaItem(url: source, kind: .image, width: 1, height: 1))
        let folder = copy.url.deletingLastPathComponent()
        let parked = directory.appendingPathComponent("parked")
        try FileManager.default.moveItem(at: folder, to: parked)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: directory)
        await assertFailure { try await self.store.remove(item) }
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: parked, to: folder)
        let root = directory.appendingPathComponent("Media")
        try FileManager.default.moveItem(at: root, to: parked)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: parked)
        await assertFailure { try await self.store.remove(item) }
        XCTAssertEqual(try Data(contentsOf: source), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.appendingPathComponent(item.id.uuidString).path))
    }

    func testCancelledCopyLeavesNoStagingDirectory() async throws {
        let source = try file("source.png", bytes: "bytes")
        let store = store!
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.stage(source: .file(source))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try contents(), [])
    }

    func testCommitConflictRollbackPreservesUnownedDestination() async throws {
        let source = try file("source.png", bytes: "original")
        let copy = try await store.stage(source: .file(source))
        let sentinel = copy.url.deletingLastPathComponent().appendingPathComponent("sentinel")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unowned".utf8).write(to: sentinel)
        await assertFailure { try await self.store.commit(copy) }
        try await store.discard(copy)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unowned".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.stagedURL.path))
    }

    func testCancellationAfterCopyStartsRemovesPartialBytes() async throws {
        let source = directory.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        let files = try XCTUnwrap(store)
        let copying = Task.detached { try await files.stage(source: .file(source)) }
        let deadline = ContinuousClock.now + .seconds(5)
        var sawPartialBytes = false
        while !sawPartialBytes, ContinuousClock.now < deadline {
            for name in try contents() where name.hasPrefix(".import-") {
                let partial = directory.appendingPathComponent("Media/\(name)/large.bin")
                if FileManager.default.fileExists(atPath: partial.path) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
                    sawPartialBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0
                }
            }
            if !sawPartialBytes { try await Task.sleep(for: .milliseconds(1)) }
        }
        copying.cancel()
        XCTAssertTrue(sawPartialBytes, "Cancellation must happen after real bytes were written")
        do { _ = try await copying.value; XCTFail("Expected in-progress copy cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try contents(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testPersistedIdentityRejectsOrdinaryDirectoryReplacement() async throws {
        let source = try file("source.png", bytes: "keep")
        let copy = try await store.stage(source: .file(source))
        try await store.commit(copy)
        let item = copy.item(from: MediaItem(url: source, kind: .image, width: 1, height: 1))
        let restored = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        let folder = item.url.deletingLastPathComponent()
        try FileManager.default.moveItem(at: folder, to: directory.appendingPathComponent("parked"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let sentinel = folder.appendingPathComponent("sentinel")
        try Data("unowned".utf8).write(to: sentinel)
        let restarted = ManagedMediaStore(directory: directory.appendingPathComponent("Media"))
        await assertFailure { try await restarted.remove(restored) }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unowned".utf8))
    }

    func testReplacedStagingDirectoryCannotCommitOrDeleteReplacement() async throws {
        let source = try file("source.png", bytes: "original")
        for symlink in [true, false] {
            let copy = try await store.stage(source: .file(source))
            let folder = copy.stagedURL.deletingLastPathComponent()
            let parked = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: folder, to: parked)
            if symlink { try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: directory) }
            else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try Data("unowned".utf8).write(to: folder.appendingPathComponent("source.png"))
            }
            await assertFailure { try await self.store.commit(copy) }
            await assertFailure { try await self.store.discard(copy) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertEqual(try Data(contentsOf: parked.appendingPathComponent("source.png")), Data("original".utf8))
            XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func file(_ path: String, bytes: String) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func contents() throws -> [String] {
        let root = directory.appendingPathComponent("Media")
        return FileManager.default.fileExists(atPath: root.path) ? try FileManager.default.contentsOfDirectory(atPath: root.path) : []
    }

    private func assertFailure(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected failure", file: file, line: line) }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line) }
    }
}
