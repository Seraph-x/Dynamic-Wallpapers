import Darwin
import XCTest
import ScreenSaverCore

final class SnapshotCleanupTests: SnapshotTestCase {
    func testPartialDeletionFailureKeepsTheLeaseUntilAllOtherContentIsRemoved() async throws {
        let old = try await fixture.publish(in: store)
        _ = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let generation = paths.generation(try XCTUnwrap(old.generationID))
        let blocked = generation.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data("cannot unlink yet".utf8).write(to: blocked.appendingPathComponent("fixture"))
        do {
            XCTAssertEqual(chmod(blocked.path, 0o555), 0)
            defer { XCTAssertEqual(chmod(blocked.path, 0o755), 0) }
            do { _ = try await store.collectGarbage(); XCTFail("The real filesystem error must surface") }
            catch {}
            XCTAssertTrue(FileManager.default.fileExists(atPath: generation.appendingPathComponent(".lease").path))
        }
        let recovered = try await store.collectGarbage()
        XCTAssertEqual(recovered.removed, [old.generationID!])
    }

    func testEmptyNonCurrentDirectoryWithoutLeaseIsRecoverableAfterDeletionCrash() async throws {
        let old = try await fixture.publish(in: store)
        let current = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let generation = paths.generation(try XCTUnwrap(old.generationID))
        for child in try FileManager.default.contentsOfDirectory(at: generation, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: child)
        }
        let collected = try await store.collectGarbage()
        XCTAssertEqual(collected.removed, [old.generationID!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: generation.path))
        let actual = try await store.current()
        XCTAssertEqual(actual, current)
    }

    func testNonEmptyGenerationWithoutLeaseIsAnErrorNotPermissionToRecreateTheLock() async throws {
        let old = try await fixture.publish(in: store)
        let current = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let generation = paths.generation(try XCTUnwrap(old.generationID))
        let lease = generation.appendingPathComponent(".lease")
        try FileManager.default.removeItem(at: lease)
        do { _ = try await store.collectGarbage(); XCTFail("No verifiable lease for a nonempty generation") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.path))
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent(fixture.file.relativePath)), fixture.bytes)
        let actual = try await store.current()
        XCTAssertEqual(actual, current)
    }
}
