import Darwin
import Foundation
import XCTest
@testable import WallpaperEditorCore

final class EditorResourceCollectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSessionProtectsAllStagedVersionsUntilLastOwnerReleases() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "History", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let savedVersion = try await store.stageResource(id: owned.document.id, data: Data([1]), session: session!)
        let historyVersion = try await store.stageResource(id: owned.document.id, data: Data([2]), session: session!)
        let saved = try await store.save(owned.document, scene: owned.document.scene, project: owned.document.project,
                                         title: "Saved", resourceOverrides: ["a.bin": savedVersion])
        let active = try await store.collectUnusedResources(id: saved.id)
        XCTAssertTrue(active.activeSession)
        XCTAssertEqual(active.removedVersions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob(saved.id, historyVersion).path))
        session = nil
        let collected = try await store.collectUnusedResources(id: saved.id)
        XCTAssertFalse(collected.activeSession)
        XCTAssertEqual(collected.removedVersions, [historyVersion.id])
        XCTAssertEqual(collected.reclaimedBytes, 1)
        XCTAssertEqual(try Data(contentsOf: blob(saved.id, savedVersion)), Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob(saved.id, historyVersion).path))
        let reopened = try await store.open(id: saved.id)
        XCTAssertEqual(reopened.document, saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.resources.appendingPathComponent("scene.json").path))
    }

    func testMalformedInventoryFailsBeforeDeletingAnyBlob() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Malformed", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let orphan = try await store.stageResource(id: owned.document.id, data: Data([1]), session: session!)
        session = nil
        let invalid = blob(owned.document.id, orphan).deletingLastPathComponent().appendingPathComponent("invalid")
        try Data([2]).write(to: invalid)
        do { _ = try await store.collectUnusedResources(id: owned.document.id); XCTFail("Accepted malformed inventory") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: blob(owned.document.id, orphan)), Data([1]))
        XCTAssertEqual(try Data(contentsOf: invalid), Data([2]))
    }

    func testRealProcessLeaseBlocksCollectionAndCrashReleasesIt() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Crash", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let orphan = try await store.stageResource(id: owned.document.id, data: Data([1, 2]), session: session!)
        let peer = try lockPeer(id: owned.document.id)
        defer { if peer.isRunning { peer.terminate(); peer.waitUntilExit() } }
        session = nil
        let blocked = try await store.collectUnusedResources(id: owned.document.id)
        XCTAssertTrue(blocked.activeSession)
        XCTAssertEqual(try Data(contentsOf: blob(owned.document.id, orphan)), Data([1, 2]))
        XCTAssertEqual(Darwin.kill(peer.processIdentifier, SIGKILL), 0)
        peer.waitUntilExit()
        let collected = try await store.collectUnusedResources(id: owned.document.id)
        XCTAssertEqual(collected.removedVersions, [orphan.id])
        XCTAssertEqual(collected.reclaimedBytes, 2)
    }

    func testMultipleLeasesProtectUntilBothOwnersRelease() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Windows", width: 10, height: 10)
        var first: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        var second: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let orphan = try await store.stageResource(id: owned.document.id, data: Data([3]), session: first!)
        first = nil
        let active = try await store.collectUnusedResources(id: owned.document.id)
        XCTAssertTrue(active.activeSession)
        XCTAssertNotNil(second)
        second = nil
        let collected = try await store.collectUnusedResources(id: owned.document.id)
        XCTAssertEqual(collected.removedVersions, [orphan.id])
    }

    func testWrongProjectSessionCannotStageAndResourceSymlinkCannotBeCollected() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Original", width: 10, height: 10)
        let other = try await store.create(title: "Other", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        do { _ = try await store.stageResource(id: other.document.id, data: Data([1]), session: session!); XCTFail("Accepted another project's lease") }
        catch {}
        let orphan = try await store.stageResource(id: owned.document.id, data: Data([1]), session: session!)
        session = nil
        let outside = root.appendingPathComponent("Outside")
        try Data([7]).write(to: outside)
        try FileManager.default.removeItem(at: blob(owned.document.id, orphan))
        try FileManager.default.createSymbolicLink(at: blob(owned.document.id, orphan), withDestinationURL: outside)
        do { _ = try await store.collectUnusedResources(id: owned.document.id); XCTFail("Accepted resource symlink") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: outside), Data([7]))
        XCTAssertTrue(try FileManager.default.destinationOfSymbolicLink(atPath: blob(owned.document.id, orphan).path) == outside.path)
    }

    func testCorruptSavedReferencePreventsDeletingUnreferencedVersions() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Corrupt", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let savedVersion = try await store.stageResource(id: owned.document.id, data: Data([1]), session: session!)
        let orphan = try await store.stageResource(id: owned.document.id, data: Data([2]), session: session!)
        _ = try await store.save(owned.document, scene: owned.document.scene, project: owned.document.project,
                                 title: "Saved", resourceOverrides: ["a.bin": savedVersion])
        session = nil
        try Data([9]).write(to: blob(owned.document.id, savedVersion))
        do { _ = try await store.collectUnusedResources(id: owned.document.id); XCTFail("Accepted corrupt saved reference") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: blob(owned.document.id, orphan)), Data([2]))
    }

    func testStoreScanReportsMalformedProjectAndNeverRemovesUnrelatedEntries() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Malformed manifest", width: 10, height: 10)
        let unrelated = root.appendingPathComponent("User folder")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data([8]).write(to: unrelated.appendingPathComponent("sentinel"))
        try Data("invalid".utf8).write(to: root.appendingPathComponent("\(owned.document.id.uuidString)/workspace.json"))
        let report = try await store.collectUnusedResources()
        XCTAssertEqual(report.failures.map(\.projectID), [owned.document.id])
        XCTAssertEqual(try Data(contentsOf: unrelated.appendingPathComponent("sentinel")), Data([8]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.resources.path))
    }

    func testRedirectedProjectCannotUseExistingSessionOrDeleteOutsideResources() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Redirect", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let orphan = try await store.stageResource(id: owned.document.id, data: Data([1]), session: session!)
        let project = root.appendingPathComponent(owned.document.id.uuidString)
        let moved = root.appendingPathComponent("Outside")
        try FileManager.default.moveItem(at: project, to: moved)
        try FileManager.default.createSymbolicLink(at: project, withDestinationURL: moved)
        do { _ = try await store.stageResource(id: owned.document.id, data: Data([2]), session: session!); XCTFail("Accepted redirected project") }
        catch {}
        session = nil
        do { _ = try await store.collectUnusedResources(id: owned.document.id); XCTFail("Collected redirected project") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("Resources/\(orphan.id)")), Data([1]))
    }

    func testCaptureRetainsLeaseAcrossSuspensionAndPublishedBytesSurviveCollection() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Capture", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let version = try await store.stageResource(id: owned.document.id, data: Data([7, 8]), session: session!)
        let draft = try EditorProjectDocument(id: owned.document.id, revision: 0, title: "Draft", sceneEntry: "scene.json",
            sourcePackage: nil, scene: owned.document.scene, project: owned.document.project, resourceOverrides: ["a.bin": version])
        for index in 0..<1024 { try Data(repeating: 7, count: 4096).write(to: owned.resources.appendingPathComponent("asset-\(index)")) }
        let destination = root.deletingLastPathComponent().appendingPathComponent("Preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }
        let capture = Task { try await store.exportPreview(draft, basedOn: owned.document, to: destination) }
        while !(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".import-") }) { await Task.yield() }
        session = nil
        let concurrent = try await EditorProjectStore(directory: root).collectUnusedResources(id: owned.document.id)
        XCTAssertTrue(concurrent.activeSession, "Capture must own its own lease after the caller releases its editing session")
        let exported = try await capture.value
        let collected = try await store.collectUnusedResources(id: owned.document.id)
        XCTAssertEqual(collected.removedVersions, [version.id])
        XCTAssertEqual(try Data(contentsOf: exported.root.appendingPathComponent("a.bin")), Data([7, 8]))
    }

    func testCollectorExcludesNewSessionUntilWorkspaceMutationCompletes() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Lock order", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let orphan = try await store.stageResource(id: owned.document.id, data: Data([1]), session: session!)
        session = nil
        let project = root.appendingPathComponent(owned.document.id.uuidString)
        let workspace = Darwin.open(project.appendingPathComponent(".workspace-lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(workspace, 0)
        defer { close(workspace) }
        XCTAssertEqual(flock(workspace, LOCK_EX), 0)
        let probe = Darwin.open(project.appendingPathComponent(".resource-session-lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(probe, 0)
        defer { close(probe) }
        let collection = Task.detached { try await store.collectUnusedResources(id: owned.document.id) }
        // The collector holds the resource lease while waiting for the workspace lock.
        while flock(probe, LOCK_SH | LOCK_NB) == 0 { XCTAssertEqual(flock(probe, LOCK_UN), 0); await Task.yield() }
        XCTAssertEqual(errno, EWOULDBLOCK)
        let other = EditorProjectStore(directory: root)
        let pendingStage = Task.detached { () throws -> (EditorResourceSession, EditorResourceVersion) in
            let session = try await other.acquireResourceSession(id: owned.document.id)
            let version = try await other.stageResource(id: owned.document.id, data: Data([2]), session: session)
            return (session, version)
        }
        XCTAssertEqual(flock(workspace, LOCK_UN), 0)
        let collected = try await collection.value
        XCTAssertEqual(collected.removedVersions, [orphan.id])
        let (newSession, version) = try await pendingStage.value
        defer { withExtendedLifetime(newSession) {} }
        XCTAssertEqual(try Data(contentsOf: blob(owned.document.id, version)), Data([2]))
        let blocked = try await store.collectUnusedResources(id: owned.document.id)
        XCTAssertTrue(blocked.activeSession)
    }

    func testResourceDirectoryRedirectedWhileCollectorWaitsCannotDeleteOutsideBytes() async throws {
        let store = EditorProjectStore(directory: root)
        let owned = try await store.create(title: "Collection race", width: 10, height: 10)
        var session: EditorResourceSession? = try await store.acquireResourceSession(id: owned.document.id)
        let orphan = try await store.stageResource(id: owned.document.id, data: Data([4]), session: session!)
        session = nil
        let project = root.appendingPathComponent(owned.document.id.uuidString)
        let workspace = Darwin.open(project.appendingPathComponent(".workspace-lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(workspace, 0)
        defer { close(workspace) }
        XCTAssertEqual(flock(workspace, LOCK_EX), 0)
        let probe = Darwin.open(project.appendingPathComponent(".resource-session-lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(probe, 0)
        defer { close(probe) }
        let collection = Task.detached { try await store.collectUnusedResources(id: owned.document.id) }
        while flock(probe, LOCK_SH | LOCK_NB) == 0 { XCTAssertEqual(flock(probe, LOCK_UN), 0); await Task.yield() }
        XCTAssertEqual(errno, EWOULDBLOCK)
        let resources = project.appendingPathComponent("Resources"), outside = root.appendingPathComponent("OutsideResources")
        try FileManager.default.moveItem(at: resources, to: outside)
        try FileManager.default.createSymbolicLink(at: resources, withDestinationURL: outside)
        XCTAssertEqual(flock(workspace, LOCK_UN), 0)
        do { _ = try await collection.value; XCTFail("Followed Resources symlink introduced after collection acquired its lease") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent(orphan.id)), Data([4]))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: resources.path), outside.path)
    }

    private func lockPeer(id: UUID) throws -> Process {
        let process = Process(), ready = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl, os, signal, sys\nf = os.open(sys.argv[1], os.O_RDWR)\nfcntl.flock(f, fcntl.LOCK_SH)\nprint('R', flush=True)\nsignal.pause()", root.appendingPathComponent("\(id.uuidString)/.resource-session-lock").path]
        process.standardOutput = ready
        try process.run()
        XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 1), Data("R".utf8))
        return process
    }

    private func blob(_ id: UUID, _ version: EditorResourceVersion) -> URL {
        root.appendingPathComponent("\(id.uuidString)/Resources/\(version.id)")
    }
}
