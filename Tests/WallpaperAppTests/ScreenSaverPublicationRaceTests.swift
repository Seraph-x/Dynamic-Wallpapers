import XCTest
import Foundation
import WallpaperCore
import ScreenSaverCore
@testable import WallpaperApp

@MainActor
final class ScreenSaverPublicationRaceTests: XCTestCase {
    func testCleanCancellationKeepsCancelledPhaseAndVisibleCode() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let gate = ScreenSaverTestGate()
        addTeardownBlock { await gate.release() }
        var operations = ScreenSaverExportOperations.system
        let copy = operations.copy
        operations.copy = { source, destination in
            let result = try await copy(source, destination)
            await gate.pause()
            return result
        }
        let publisher = try await fixture.makePublisher(exportOperations: operations)
        let publication = publisher.request(library: fixture.library, settings: fixture.settings)
        try await gate.waitForArrival()
        publication.cancel()
        await gate.release()

        _ = try await screenSaverFailure { try await publication.value }

        XCTAssertEqual(publisher.state.phase, .cancelled)
        XCTAssertEqual(publisher.state.failure?.code, .cancelled(.publish))
        let current = try await fixture.store.current()
        XCTAssertNil(current)
    }

    func testNewRequestWaitsForActualWorkerReturnAndCannotBeOverwrittenByTheOldOne() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let gate = ScreenSaverTestGate()
        addTeardownBlock { await gate.release() }
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.copy = { source, destination in
            let result = try await real.copy(source, destination)
            await gate.pause()
            return result
        }
        let publisher = try await f.makePublisher(exportOperations: operations)
        let first = publisher.request(library: f.library, settings: f.settings)
        try await gate.waitForArrival()
        let changed = ScreenSaverSettings(source: f.settings.source, isMuted: false, fit: .fit)
        let second = publisher.request(library: f.library, settings: changed)
        try await Task.sleep(for: .milliseconds(20))
        let beforeRelease = try await f.store.current()
        XCTAssertNil(beforeRelease)
        XCTAssertTrue(publisher.hasActiveWork)
        await gate.release()
        _ = try await screenSaverFailure { try await first.value }
        let current = try await second.value
        XCTAssertEqual(publisher.state.published, current)
        let selected = try await f.store.acquireCurrent()
        let lease = try XCTUnwrap(selected)
        XCTAssertFalse(lease.manifest.isMuted)
        XCTAssertEqual(lease.manifest.fit, .fit)
        try await lease.close()
        XCTAssertFalse(publisher.hasActiveWork)
    }

    func testRemovalBarrierWaitsForCopyAndValidationToActuallyFinish() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let gate = ScreenSaverTestGate()
        addTeardownBlock { await gate.release() }
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.inspect = { url in
            let result = try await real.inspect(url)
            await gate.pause()
            return result
        }
        let publisher = try await f.makePublisher(exportOperations: operations)
        let publication = publisher.request(library: f.library, settings: f.settings)
        try await gate.waitForArrival()
        let removing = publisher.beginRemovingMedia([f.item.id])
        var deleted = false
        let physicalRemoval = Task { @MainActor in
            try await removing.value
            try FileManager.default.removeItem(at: f.item.url)
            deleted = true
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(deleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.item.url.path))
        await gate.release()
        try await physicalRemoval.value
        _ = try await screenSaverFailure { try await publication.value }
        let current = try await f.store.current()
        XCTAssertNil(current)
        _ = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings).value }
    }

    func testSourceReplacementAfterCopyIsDetectedBeforePublication() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let gate = ScreenSaverTestGate()
        addTeardownBlock { await gate.release() }
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.copy = { input, destination in
            let result = try await real.copy(input, destination)
            await gate.pause()
            return result
        }
        let publisher = try await f.makePublisher(exportOperations: operations)
        let publication = publisher.request(library: f.library, settings: f.settings)
        try await gate.waitForArrival()
        let bytes = try Data(contentsOf: f.item.url)
        try bytes.write(to: f.item.url, options: .atomic)
        await gate.release()
        let error = try await screenSaverFailure { try await publication.value }
        let failure = try XCTUnwrap(error as? ScreenSaverPublishFailure)
        XCTAssertEqual(failure.state.failure?.code, .sourceChanged(f.item.url.lastPathComponent))
        let current = try await f.store.current()
        XCTAssertNil(current)
    }

    func testIndependentWriterTargetChangeInvalidatesPausedPublication() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let gate = ScreenSaverTestGate()
        addTeardownBlock { await gate.release() }
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.copy = { input, destination in
            let result = try await real.copy(input, destination)
            await gate.pause()
            return result
        }
        let publisher = try await f.makePublisher(exportOperations: operations)
        let publication = publisher.request(library: f.library, settings: f.settings)
        try await gate.waitForArrival()
        let independent = try f.makeSettingsStore()
        let oldTarget = try await independent.load()
        let changed = try await independent.save(f.settings.selecting(nil), sourceRevision: nil,
                                                 replacing: try XCTUnwrap(oldTarget).revision)
        await gate.release()
        _ = try await screenSaverFailure { try await publication.value }
        let current = try await f.store.current()
        XCTAssertNil(current)
        let actual = try await independent.load()
        XCTAssertEqual(actual, changed)
    }

    func testShutdownWaitsForActualWorkerReturnAndRejectsNewRequests() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let gate = ScreenSaverTestGate()
        addTeardownBlock { await gate.release() }
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.copy = { input, destination in
            let result = try await real.copy(input, destination)
            await gate.pause()
            return result
        }
        let publisher = try await f.makePublisher(exportOperations: operations)
        let publication = publisher.request(library: f.library, settings: f.settings)
        try await gate.waitForArrival()
        let shutdown = publisher.beginShutdown()
        var stopped = false
        let observer = Task { try await shutdown.value; stopped = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(stopped)
        XCTAssertTrue(publisher.hasActiveWork)
        _ = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings).value }
        await gate.release()
        try await observer.value
        _ = try await screenSaverFailure { try await publication.value }
        XCTAssertFalse(publisher.hasActiveWork)
    }
}
