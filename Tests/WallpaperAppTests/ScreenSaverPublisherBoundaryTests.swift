import XCTest
import Darwin
import Foundation
import WallpaperCore
import ScreenSaverCore
@testable import WallpaperApp

@MainActor
final class ScreenSaverPublisherBoundaryTests: XCTestCase {
    func testInvalidatedJobStillReportsItsCommitAndLossOfVerification() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let initial = try await f.makePublisher()
        let old = try await initial.request(library: f.library, settings: f.settings).value
        let entered = ScreenSaverCommitGate()
        let real = ScreenSaverStoreOperations.system
        var operations = real
        operations.replacePointer = { root, source in
            try real.replacePointer(root, source)
            try entered.pause()
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        }
        let publisher = try await f.makePublisher(storeOperations: operations)
        let publication = publisher.request(library: f.library, settings: f.settings, force: true)
        while !entered.arrived { try await Task.sleep(for: .milliseconds(5)) }
        let removing = publisher.beginRemovingMedia([f.item.id])
        entered.release()
        let result = await publication.result
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.store.paths.root.path)
        guard case .failure = result else { return XCTFail("Expected post-commit failure") }
        _ = try await screenSaverFailure { try await removing.value }
        let committed = try await f.store.current()
        XCTAssertNotEqual(committed, old)
        XCTAssertEqual(publisher.state.published, committed)
        XCTAssertFalse(publisher.state.currentVerified)
        XCTAssertEqual(publisher.state.phase, .sourceInvalid, "Late results must not replace the removal status")
    }

    func testCommittedPointerIsRetainedWhenPostCommitSyncAndDiagnosticReadBothFail() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let initial = try await f.makePublisher()
        let old = try await initial.request(library: f.library, settings: f.settings).value
        let real = ScreenSaverStoreOperations.system
        var operations = real
        operations.replacePointer = { root, source in
            try real.replacePointer(root, source)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        }
        let publisher = try await f.makePublisher(storeOperations: operations)
        let result = await publisher.request(library: f.library, settings: f.settings, force: true).result
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.store.paths.root.path)
        guard case .failure(let error) = result else { return XCTFail("Expected post-commit failure") }
        let failure = try XCTUnwrap(error as? ScreenSaverPublishFailure)
        XCTAssertEqual(failure.state.failure?.code, .publicationFailed)
        XCTAssertEqual(failure.state.failure?.reasons.map(\.code),
                       [.committedThenFailed, .settingsUnavailable, .pointerUnavailable])
        XCTAssertTrue(failure.underlying.localizedDescription.contains("Permission denied"))
        let committed = try await f.store.current()
        XCTAssertNotEqual(committed, old)
        XCTAssertEqual(publisher.state.published, committed, "Preserve the known commit even when it cannot be reverified")
        XCTAssertFalse(publisher.state.currentVerified)
        XCTAssertEqual(publisher.state.phase, .failed)
    }

    func testBusyIndependentWriterIsVisibleAndNeverOverwritesOrCleansItsStage() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        _ = try await publisher.request(library: f.library, settings: f.settings).value
        let current = try Data(contentsOf: f.store.paths.current)
        let stage = try await f.store.beginPublication()
        let error = try await screenSaverFailure {
            try await publisher.request(library: f.library, settings: f.settings, force: true).value
        }
        XCTAssertTrue(error.localizedDescription.contains(ScreenSaverFileLockError.busy.localizedDescription))
        XCTAssertEqual(publisher.state.phase, .failed)
        XCTAssertEqual(try Data(contentsOf: f.store.paths.current), current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.directory.path))
        try await f.store.abort(stage)
        _ = try await publisher.request(library: f.library, settings: f.settings, force: true).value
        XCTAssertEqual(publisher.state.phase, .published)
    }

    func testFailedReloadRequiresSuccessfulReloadBeforeAnotherPublication() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        _ = try await publisher.request(library: f.library, settings: f.settings).value
        let settings = try Data(contentsOf: f.settingsURL)
        let current = try Data(contentsOf: f.store.paths.current)
        try Data("broken settings".utf8).write(to: f.settingsURL)
        _ = try await screenSaverFailure { try await publisher.load() }
        try settings.write(to: f.settingsURL)
        _ = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings, force: true).value }
        XCTAssertEqual(try Data(contentsOf: f.store.paths.current), current)
        try await publisher.load()
        _ = try await publisher.request(library: f.library, settings: f.settings, force: true).value
    }

    func testActualCopyPermissionDenialPreservesOldPublication() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let initial = try await f.makePublisher()
        _ = try await initial.request(library: f.library, settings: f.settings).value
        let current = try Data(contentsOf: f.store.paths.current)
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.copy = { input, destination in
            let directory = destination.url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            let result: Result<ScreenSaverCopyDigest, Error>
            do { result = .success(try await real.copy(input, destination)) }
            catch { result = .failure(error) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return try result.get()
        }
        let publisher = try await f.makePublisher(exportOperations: operations)
        let error = try await screenSaverFailure {
            try await publisher.request(library: f.library, settings: f.settings, force: true).value
        }
        XCTAssertTrue(error.localizedDescription.contains("Permission denied"), error.localizedDescription)
        XCTAssertEqual(try Data(contentsOf: f.store.paths.current), current)
    }

    func testFailedSourceCloseRetainsTheRealDescriptorAndBlocksRemovalAndShutdown() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let witness = ScreenSaverSourceWitness()
        var operations = ScreenSaverExportOperations.system
        operations.closeSource = { source in
            witness.capture(source)
            throw WallpaperError("injected source close failure")
        }
        // Deliberately not registered for the fixture's successful-shutdown assertion: failure is the assertion here.
        let publisher = ScreenSaverPublisher(store: f.store, settingsStore: try f.makeSettingsStore(),
                                               builder: ScreenSaverExportBuilder(operations: operations))
        try await publisher.load()
        _ = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings).value }
        let source = try XCTUnwrap(witness.source)
        addTeardownBlock { try source.close() }
        XCTAssertNotEqual(fcntl(source.handle.fileDescriptor, F_GETFD), -1, "Real source FD must still be owned")
        let removal = try await screenSaverFailure { try await publisher.beginRemovingMedia([f.item.id]).value }
        XCTAssertTrue(removal.localizedDescription.contains("injected source close failure"))
        let shutdown = try await screenSaverFailure { try await publisher.beginShutdown().value }
        XCTAssertTrue(shutdown.localizedDescription.contains("injected source close failure"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.item.url.path))
        let current = try await f.store.current()
        XCTAssertNil(current)
    }

    func testRepeatedRequestsDoNotDuplicateRetainedCloseFailures() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let witness = ScreenSaverSourceWitness()
        var operations = ScreenSaverExportOperations.system
        operations.closeSource = { source in
            witness.capture(source)
            throw WallpaperError("one retained descriptor")
        }
        let publisher = ScreenSaverPublisher(store: f.store, settingsStore: try f.makeSettingsStore(),
                                               builder: ScreenSaverExportBuilder(operations: operations))
        try await publisher.load()
        _ = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings).value }
        let source = try XCTUnwrap(witness.source)
        addTeardownBlock { try source.close() }
        for _ in 0..<4 {
            let error = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings).value }
            XCTAssertEqual(error.localizedDescription.components(separatedBy: "one retained descriptor").count - 1, 1)
        }
        let shutdown = try await screenSaverFailure { try await publisher.beginShutdown().value }
        XCTAssertEqual(shutdown.localizedDescription.components(separatedBy: "one retained descriptor").count - 1, 1)
    }

    func testNewUnconfirmedExclusionCannotOverwriteThePreviousPublication() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        let old = try await publisher.request(library: f.library, settings: f.settings).value
        var mixed = f.library
        let extended = MediaItem(url: f.directory.appendingPathComponent("not-opened.mkv"), kind: .video,
                                 width: 16, height: 16, duration: 1, backend: .extended)
        mixed.media.append(extended)
        mixed.playlists[0].entries.append(PlaylistEntry(mediaID: extended.id))
        _ = try await screenSaverFailure { try await publisher.request(library: mixed, settings: f.settings).value }
        XCTAssertEqual(publisher.state.phase, .needsConfirmation)
        XCTAssertEqual(publisher.state.published, old)
        let projection = try ScreenSaverProjection(library: mixed, source: f.settings.source!)
        let consent = ScreenSaverConsent(acknowledging: projection)
        let confirmed = try f.settings.confirming(consent)
        _ = try await publisher.request(library: mixed, settings: confirmed).value
        let selected = try await f.store.acquireCurrent()
        let lease = try XCTUnwrap(selected)
        XCTAssertEqual(lease.manifest.entries, f.library.playlists[0].entries)
        XCTAssertEqual(mixed.playlists[0].entries.count, 3)
        try await lease.close()
    }

    func testDamagedCurrentPointerNeverBecomesAVerifiedFallback() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        let old = try await publisher.request(library: f.library, settings: f.settings).value
        try Data("broken current".utf8).write(to: f.store.paths.current)
        _ = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings, force: true).value }
        XCTAssertEqual(publisher.state.published, old, "A last observed pointer may be shown only as unverified history")
        XCTAssertFalse(publisher.state.currentVerified)
        XCTAssertTrue(publisher.state.failure?.reasons.contains { $0.code == .pointerUnavailable } == true)
        XCTAssertEqual(try Data(contentsOf: f.store.paths.current), Data("broken current".utf8))
    }
}

private final class ScreenSaverSourceWitness: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: ScreenSaverSourceFile?
    func capture(_ source: ScreenSaverSourceFile) { lock.lock(); defer { lock.unlock() }; value = source }
    var source: ScreenSaverSourceFile? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class ScreenSaverCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value = false
    var arrived: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func pause() throws {
        lock.lock(); value = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 3) == .success else { throw WallpaperError("Commit test gate timed out") }
    }
    func release() { semaphore.signal() }
}
