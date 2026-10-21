import Darwin
import XCTest
import WallpaperCore
@testable import ScreenSaverCore

final class SnapshotBoundaryTests: SnapshotTestCase {
    func testMissingOrInvalidGenerationLeaseCannotBecomeCurrent() async throws {
        _ = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let original = try Data(contentsOf: paths.current)
        for mutation in 0..<5 {
            let stage = try await fixture.stage(in: store)
            let lease = stage.directory.appendingPathComponent(".lease")
            try FileManager.default.removeItem(at: lease)
            switch mutation {
            case 1: try FileManager.default.createSymbolicLink(at: lease, withDestinationURL: paths.catalogLock)
            case 2: try FileManager.default.createDirectory(at: lease, withIntermediateDirectories: false)
            case 3: XCTAssertEqual(mkfifo(lease.path, 0o600), 0)
            case 4: try FileManager.default.linkItem(at: paths.catalogLock, to: lease)
            default: break
            }
            do {
                _ = try await store.commit(stage, manifest: fixture.manifest(id: stage.id), settingsRevision: UUID())
                XCTFail("A generation without an independent regular lease must not commit: \(mutation)")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: paths.current), original, "mutation \(mutation)")
        }
    }

    func testSymlinkRegistrationParentDoesNotReceiveAStagedGeneration() async throws {
        let paths = try ScreenSaverPaths(root: directory)
        let outside = directory.appendingPathComponent("not-generations", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let stage = try await fixture.stage(in: store)
        try FileManager.default.removeItem(at: paths.generations)
        try FileManager.default.createSymbolicLink(at: paths.generations, withDestinationURL: outside)
        do {
            _ = try await store.commit(stage, manifest: fixture.manifest(id: stage.id), settingsRevision: UUID())
            XCTFail("A symlink parent must fail before the rename, not after writing outside generations")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.current.path))
    }

    func testRemovalRejectsParentSymlinkAtTheFilesystemBoundary() async throws {
        let root = directory!
        let outside = root.appendingPathComponent("not-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        var operations = ScreenSaverStoreOperations.system
        let remove = operations.removeDirectory
        operations.removeDirectory = { root, relative in
            let staging = root.appendingPathComponent("staging")
            let victim = outside.appendingPathComponent(URL(fileURLWithPath: relative).lastPathComponent)
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
            try Data("must remain untouched".utf8).write(to: victim.appendingPathComponent("sentinel"))
            try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent("original-staging"))
            try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: outside)
            try remove(root, relative)
        }
        let altered = try ScreenSaverSnapshotStore(root: root, operations: operations)
        let stage = try await fixture.stage(in: altered)
        do { try await altered.abort(stage); XCTFail("Deletion must not follow a replaced parent") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent(stage.id.uuidString + "/sentinel")),
                       Data("must remain untouched".utf8))
    }

    func testMissingIdentityIsNotRegeneratedForAnExistingPublication() async throws {
        _ = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let before = try Data(contentsOf: paths.current)
        try FileManager.default.removeItem(at: paths.identity)
        let reopened = try ScreenSaverSnapshotStore(root: directory)
        do { _ = try await reopened.initialize(); XCTFail("Existing content must not acquire a new identity") }
        catch { XCTAssertEqual(ScreenSaverFailure(capturing: error).code, .identityMissing) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.identity.path))
        XCTAssertEqual(try Data(contentsOf: paths.current), before)
    }

    func testPointerCommittedThenReportedFailureIsNotMisrepresentedAsRollback() async throws {
        var operations = ScreenSaverStoreOperations.system
        let replace = operations.replacePointer
        operations.replacePointer = { source, destination in
            try replace(source, destination)
            throw WallpaperError("injected post-rename failure")
        }
        let failing = try ScreenSaverSnapshotStore(root: directory, operations: operations)
        let stage = try await fixture.stage(in: failing)
        do {
            _ = try await failing.commit(stage, manifest: fixture.manifest(id: stage.id), settingsRevision: UUID())
            XCTFail("Post-commit errors must be observable")
        } catch {
            let failure = try XCTUnwrap(error as? ScreenSaverPublicationFailure)
            XCTAssertEqual(failure.committed?.generationID, stage.id)
            XCTAssertEqual(failure.failure.code, .committedThenFailed)
            XCTAssertTrue(containsDiagnostic("injected post-rename failure", in: failure.failure))
        }
        let current = try await store.current()
        XCTAssertEqual(current?.generationID, stage.id)
        let opened = try await store.acquireCurrent()
        let lease = try XCTUnwrap(opened)
        try await lease.close()
    }

    func testCleanupFailureIsVisibleAndLeftoverStagingCanBeRecovered() async throws {
        var operations = ScreenSaverStoreOperations.system
        operations.removeDirectory = { _, _ in throw WallpaperError("injected cleanup failure") }
        let failing = try ScreenSaverSnapshotStore(root: directory, operations: operations)
        let stage = try await fixture.stage(in: failing)
        do {
            _ = try await failing.commit(stage, manifest: fixture.manifest(id: UUID()), settingsRevision: UUID())
            XCTFail("The invalid manifest and cleanup failure must both remain visible")
        } catch {
            let failure = try XCTUnwrap(error as? ScreenSaverPublicationFailure)
            XCTAssertEqual(failure.failure.code, .publicationFailed)
            XCTAssertEqual(failure.failure.reasons.first?.code, .transactionConflict(.commit))
            XCTAssertTrue(containsDiagnostic("injected cleanup failure", in: failure.failure))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.directory.path))
        let recovered = try await store.recoverStaging()
        XCTAssertEqual(recovered, [stage.id])
    }

    private func containsDiagnostic(_ text: String, in failure: ScreenSaverFailure) -> Bool {
        failure.diagnostic?.localizedDescription.contains(text) == true
            || failure.reasons.contains { containsDiagnostic(text, in: $0) }
    }
}
