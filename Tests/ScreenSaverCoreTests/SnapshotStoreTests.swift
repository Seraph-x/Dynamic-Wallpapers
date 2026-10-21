import XCTest
import Darwin
import WallpaperCore
@testable import ScreenSaverCore

final class SnapshotStoreTests: SnapshotTestCase {
    func testInitializationAllowsFinderMetadataButRejectsOtherExistingContent() async throws {
        let metadataOnly = directory.appendingPathComponent("metadata-only")
        try FileManager.default.createDirectory(
            at: metadataOnly.appendingPathComponent("staging"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: metadataOnly.appendingPathComponent("generations"),
            withIntermediateDirectories: true
        )
        for url in [
            metadataOnly.appendingPathComponent(".DS_Store"),
            metadataOnly.appendingPathComponent("staging/.DS_Store"),
            metadataOnly.appendingPathComponent("generations/.DS_Store"),
        ] {
            try Data("finder metadata".utf8).write(to: url)
        }

        let metadataStore = try ScreenSaverSnapshotStore(root: metadataOnly)
        _ = try await metadataStore.initialize()

        let unknownContent = directory.appendingPathComponent("unknown-content")
        try FileManager.default.createDirectory(at: unknownContent, withIntermediateDirectories: true)
        try Data("must not be adopted".utf8).write(to: unknownContent.appendingPathComponent("unexpected"))
        let unknownStore = try ScreenSaverSnapshotStore(root: unknownContent)
        do {
            _ = try await unknownStore.initialize()
            XCTFail("Unknown existing content must not be adopted")
        } catch {
            XCTAssertEqual(ScreenSaverFailure(capturing: error).code, .identityMissing)
        }
    }

    func testInitializationIsStableAndNoPublicationIsNotSuccess() async throws {
        let identity = try await store.initialize()
        let other = try ScreenSaverSnapshotStore(root: directory, expectedExportID: identity.id)
        let reopened = try await other.initialize()
        XCTAssertEqual(reopened, identity)
        let current = try await other.current()
        let lease = try await other.acquireCurrent()
        XCTAssertNil(current)
        XCTAssertNil(lease)
    }

    func testCommitPublishesCompleteImmutableGenerationAndPointer() async throws {
        let current = try await fixture.publish(in: store)
        let opened = try await store.acquireCurrent()
        let lease = try XCTUnwrap(opened)
        addTeardownBlock { try await lease.close() }
        XCTAssertEqual(lease.manifest.generationID, current.generationID)
        XCTAssertEqual(lease.manifest.sourceRevision, current.sourceRevision)
        XCTAssertEqual(try Data(contentsOf: lease.directory.appendingPathComponent(fixture.file.relativePath)), fixture.bytes)
        let paths = try ScreenSaverPaths(root: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.staging.path), [])
        XCTAssertEqual(try JSONDecoder().decode(ScreenSaverCurrentPointer.self, from: Data(contentsOf: paths.current)), current)
        try await lease.close()
    }

    func testCurrentGenerationCannotBeCollectedWithoutReaders() async throws {
        let current = try await fixture.publish(in: store)
        let result = try await store.collectGarbage()
        XCTAssertTrue(result.removed.isEmpty)
        let paths = try ScreenSaverPaths(root: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.generation(try XCTUnwrap(current.generationID)).path))
    }

    func testFailureBeforePointerReplacePreservesExactOldPointerAndRecoverableOrphan() async throws {
        let old = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let before = try Data(contentsOf: paths.current)
        var operations = ScreenSaverStoreOperations.system
        operations.replacePointer = { _, _ in throw WallpaperError("injected pointer write failure") }
        let failing = try ScreenSaverSnapshotStore(root: directory, operations: operations)
        let stage = try await fixture.stage(in: failing)
        do {
            _ = try await failing.commit(stage, manifest: fixture.manifest(id: stage.id), settingsRevision: UUID())
            XCTFail("Expected pointer replacement failure")
        } catch {
            let failure = try XCTUnwrap(error as? ScreenSaverPublicationFailure)
            XCTAssertEqual(failure.failure.code, .publicationFailed)
            XCTAssertTrue(containsDiagnostic("injected pointer write failure", in: failure.failure))
        }
        XCTAssertEqual(try Data(contentsOf: paths.current), before)
        let actual = try await store.current()
        XCTAssertEqual(actual, old)
        let cleanup = try await store.collectGarbage()
        XCTAssertEqual(cleanup.removed, [stage.id])
    }

    func testStaleTargetAndMismatchedManifestCannotCommit() async throws {
        _ = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let before = try Data(contentsOf: paths.current)
        let stage = try await fixture.stage(in: store)
        do {
            _ = try await store.commit(stage, manifest: fixture.manifest(id: stage.id), settingsRevision: UUID(),
                                       validateTarget: { throw WallpaperError("stale target") })
            XCTFail("A stale target must not commit")
        } catch {
            let failure = try XCTUnwrap(error as? ScreenSaverPublicationFailure)
            XCTAssertEqual(failure.failure.code, .publicationFailed)
            XCTAssertTrue(containsDiagnostic("stale target", in: failure.failure))
        }
        XCTAssertEqual(try Data(contentsOf: paths.current), before)
        let second = try await fixture.stage(in: store)
        do {
            _ = try await store.commit(second, manifest: fixture.manifest(id: UUID()), settingsRevision: UUID())
            XCTFail("Mismatched generation identity must fail")
        } catch {
            let failure = try XCTUnwrap(error as? ScreenSaverPublicationFailure)
            XCTAssertEqual(failure.failure.reasons.first?.code, .transactionConflict(.commit))
        }
        XCTAssertEqual(try Data(contentsOf: paths.current), before)
    }

    func testActiveStagingIsProtectedByTheSamePublicationLock() async throws {
        let stage = try await fixture.stage(in: store)
        let other = try ScreenSaverSnapshotStore(root: directory)
        do { _ = try await other.recoverStaging(); XCTFail("Active staging must be protected") }
        catch { XCTAssertEqual(error as? ScreenSaverFileLockError, .busy) }
        do { _ = try await other.beginPublication(); XCTFail("A second writer must not overlap") }
        catch { XCTAssertEqual(error as? ScreenSaverFileLockError, .busy) }
        let cleanup = try await other.collectGarbage()
        XCTAssertTrue(cleanup.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.directory.path))
        try await store.abort(stage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.directory.path))
    }

    func testCorruptMediaAndNonRegularFilesNeverReplaceCurrent() async throws {
        _ = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let before = try Data(contentsOf: paths.current)
        for mutation in 0..<4 {
            let stage = try await fixture.stage(in: store)
            let url = stage.directory.appendingPathComponent(fixture.file.relativePath)
            try FileManager.default.removeItem(at: url)
            switch mutation {
            case 0: try Data("corrupt".utf8).write(to: url)
            case 1: try FileManager.default.createSymbolicLink(at: url, withDestinationURL: paths.current)
            case 2: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            default: XCTAssertEqual(mkfifo(url.path, 0o600), 0)
            }
            do {
                _ = try await store.commit(stage, manifest: fixture.manifest(id: stage.id), settingsRevision: UUID())
                XCTFail("Invalid media must not publish")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: paths.current), before)
        }
    }

    func testReaderRejectsCorruptCurrentOrManifestWithoutUsingAnOlderGeneration() async throws {
        _ = try await fixture.publish(in: store)
        let current = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let generation = paths.generation(try XCTUnwrap(current.generationID))
        try Data("broken manifest".utf8).write(to: generation.appendingPathComponent("manifest.json"))
        do { _ = try await store.acquireCurrent(); XCTFail("Corrupt manifest must fail") }
        catch {}
        let lock = try ScreenSaverFileLock.acquire(root: directory,
            relativePath: "generations/\(current.generationID!.uuidString)/.lease", mode: .exclusive, nonBlocking: true)
        try lock.close()
        try Data("broken pointer".utf8).write(to: paths.current)
        do { _ = try await store.acquireCurrent(); XCTFail("Corrupt pointer must fail") }
        catch {}
    }

    func testExportIdentityMismatchIsNotAdoptedOrReplaced() async throws {
        _ = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        let identity = try Data(contentsOf: paths.identity)
        let wrong = try ScreenSaverSnapshotStore(root: directory, expectedExportID: UUID())
        do { _ = try await wrong.acquireCurrent(); XCTFail("A different export must require explicit authorization") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: paths.identity), identity)
        try Data("bad identity".utf8).write(to: paths.identity)
        do { _ = try await store.initialize(); XCTFail("A damaged identity must not be reset") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: paths.identity), Data("bad identity".utf8))
    }

    func testDisableIsAtomicAndKeepsAnExistingReaderUntilRelease() async throws {
        let first = try await fixture.publish(in: store)
        let opened = try await store.acquireCurrent()
        let reader = try XCTUnwrap(opened)
        addTeardownBlock { try await reader.close() }
        let disabled = try await store.disable(settingsRevision: UUID())
        XCTAssertNil(disabled.generationID)
        let newReader = try await store.acquireCurrent()
        XCTAssertNil(newReader)
        let inUse = try await store.collectGarbage()
        XCTAssertEqual(inUse.retained, [first.generationID!])
        try await reader.close()
        let released = try await store.collectGarbage()
        XCTAssertEqual(released.removed, [first.generationID!])
    }

    func testFinderMetadataDoesNotBlockGenerationOrStagingRecovery() async throws {
        let old = try await fixture.publish(in: store)
        let current = try await fixture.publish(in: store)
        let paths = try ScreenSaverPaths(root: directory)
        try Data("finder metadata".utf8).write(to: paths.generations.appendingPathComponent(".DS_Store"))
        try Data("finder metadata".utf8).write(to: paths.staging.appendingPathComponent(".DS_Store"))

        let collected = try await store.collectGarbage()
        XCTAssertEqual(collected.removed, [old.generationID!])
        let actual = try await store.current()
        let recovered = try await store.recoverStaging()
        XCTAssertEqual(actual, current)
        XCTAssertEqual(recovered, [])
    }

    func testUnknownGenerationEntryStillFailsGarbageCollection() async throws {
        let paths = try ScreenSaverPaths(root: directory)
        try Data("unexpected".utf8).write(to: paths.generations.appendingPathComponent("unexpected"))

        do {
            _ = try await store.collectGarbage()
            XCTFail("Unknown generation content must remain visible")
        } catch {
            XCTAssertEqual(ScreenSaverFailure(capturing: error).code, .invalidPath("unexpected"))
        }
    }

    private func containsDiagnostic(_ text: String, in failure: ScreenSaverFailure) -> Bool {
        failure.diagnostic?.localizedDescription.contains(text) == true
            || failure.reasons.contains { containsDiagnostic(text, in: $0) }
    }
}
