import XCTest
import CryptoKit
import Darwin
import UniformTypeIdentifiers
import WallpaperCore
import WallpaperNative
import ScreenSaverCore
@testable import WallpaperApp

@MainActor
final class ScreenSaverPublisherTests: XCTestCase {
    func testWrappedCleanCancellationKeepsVisibleCancellationCode() {
        let cancelled = ScreenSaverPublicationFailure(committed: nil, errors: [CancellationError()])
        XCTAssertTrue(ScreenSaverPublishFailure.isCleanCancellation(cancelled))
        XCTAssertEqual(ScreenSaverAppFailure.capture(cancelled, phase: .publish).code, .cancelled(.publish))
    }

    func testPublishesAnIndependentCopyAndKeepsRepeatedEntriesAndPlaybackSettings() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        let before = f.library
        let published = try await publisher.request(library: f.library, settings: f.settings).value
        let pointer = try XCTUnwrap(published)
        let selected = try await f.store.acquireCurrent()
        let lease = try XCTUnwrap(selected)
        addTeardownBlock { try await lease.close() }
        XCTAssertEqual(lease.manifest.entries, f.library.playlists[0].entries)
        XCTAssertEqual(lease.manifest.mode, .shuffle)
        XCTAssertEqual(lease.manifest.transition, 0.2)
        XCTAssertTrue(lease.manifest.isMuted)
        XCTAssertEqual(lease.manifest.files.count, 1)
        XCTAssertEqual(lease.manifest.generationID, pointer.generationID)
        let copy = lease.directory.appendingPathComponent(lease.manifest.files[0].relativePath)
        let bytes = try Data(contentsOf: copy)
        XCTAssertEqual(bytes, try Data(contentsOf: f.item.url))
        XCTAssertEqual(lease.manifest.files[0].sha256,
                       SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let sourceInfo = try FileManager.default.attributesOfItem(atPath: f.item.url.path)
        let copyInfo = try FileManager.default.attributesOfItem(atPath: copy.path)
        XCTAssertNotEqual(sourceInfo[.systemFileNumber] as? NSNumber, copyInfo[.systemFileNumber] as? NSNumber)
        try FileManager.default.removeItem(at: f.item.url)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertEqual(f.library, before)
        XCTAssertEqual(publisher.state.phase, .published)
        XCTAssertEqual(publisher.state.published, pointer)
        let manifestText = String(decoding: try Data(contentsOf: lease.directory.appendingPathComponent("manifest.json")), as: UTF8.self)
        XCTAssertFalse(manifestText.contains(f.item.url.path))
    }

    func testUnrelatedLibraryChangesDoNotRepublishButManualSyncDoes() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        let first = try await publisher.request(library: f.library, settings: f.settings).value
        var unrelated = f.library
        unrelated.media[0].isFavorite.toggle()
        unrelated.playlists.append(Playlist(name: "Unrelated"))
        let second = try await publisher.request(library: unrelated, settings: f.settings).value
        XCTAssertEqual(first, second)
        let refreshed = try await publisher.request(library: unrelated, settings: f.settings, force: true).value
        XCTAssertNotEqual(first?.generationID, refreshed?.generationID)
    }

    func testReprobesRealGIFAPNGAndVideoCopies() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        let generated = [try MediaTests.makeImage(type: UTType.gif.identifier, frames: 2),
                         try MediaTests.makeImage(type: UTType.png.identifier, frames: 2),
                         try await VideoIntegrationTests.makeVideo()]
        for (index, original) in generated.enumerated() {
            let source = f.directory.appendingPathComponent("generated-\(index).\(original.pathExtension)")
            try FileManager.default.moveItem(at: original, to: source)
            let item = try await NativeMediaProbe.inspect(source)
            var library = Library(); library.media = [item]
            _ = try await publisher.request(library: library, settings: ScreenSaverSettings(source: .media(item.id))).value
            let selected = try await f.store.acquireCurrent()
            let lease = try XCTUnwrap(selected)
            let file = try XCTUnwrap(lease.manifest.files.first)
            XCTAssertEqual(file.kind, item.kind)
            XCTAssertEqual(file.duration, item.duration)
            let inspected = try await NativeMediaProbe.inspect(lease.directory.appendingPathComponent(file.relativePath))
            XCTAssertEqual(inspected.kind, item.kind)
            try await lease.close()
        }
    }

    func testCorruptSupportedMediaPreservesOldPointerAndReportsFailure() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        let old = try await publisher.request(library: f.library, settings: f.settings).value
        let bytes = try Data(contentsOf: f.store.paths.current)
        try Data("not an image".utf8).write(to: f.item.url)
        _ = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings, force: true).value }
        XCTAssertEqual(try Data(contentsOf: f.store.paths.current), bytes)
        XCTAssertEqual(publisher.state.published, old)
        XCTAssertEqual(publisher.state.phase, .failed)
        XCTAssertNotNil(publisher.state.failure)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.store.paths.staging.path).isEmpty)
    }

    func testCopyErrorsAndCleanupErrorsAreBothVisible() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let working = try await f.makePublisher()
        _ = try await working.request(library: f.library, settings: f.settings).value
        let before = try Data(contentsOf: f.store.paths.current)
        var copy = ScreenSaverExportOperations.system
        copy.copy = { _, _ in throw POSIXError(.ENOSPC) }
        var storage = ScreenSaverStoreOperations.system
        storage.removeDirectory = { _, _ in throw WallpaperError("staging cleanup denied") }
        let failing = try await f.makePublisher(exportOperations: copy, storeOperations: storage)
        let error = try await screenSaverFailure {
            try await failing.request(library: f.library, settings: f.settings, force: true).value
        }
        XCTAssertTrue(error.localizedDescription.contains("staging cleanup denied"))
        XCTAssertTrue(error.localizedDescription.contains(POSIXError(.ENOSPC).localizedDescription))
        XCTAssertEqual(try Data(contentsOf: f.store.paths.current), before)
        XCTAssertEqual(failing.state.phase, .failed)
    }

    func testPointerIsTheFactWhenPublicationReceiptWriteFails() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let real = ScreenSaverSettingsOperations.system
        var operations = real
        operations.replaceDocument = { bytes, url in
            if url.lastPathComponent == "screensaver-publication.json" { throw WallpaperError("receipt write denied") }
            try real.replaceDocument(bytes, url)
        }
        let publisher = try await f.makePublisher(settingsOperations: operations)
        let error = try await screenSaverFailure { try await publisher.request(library: f.library, settings: f.settings).value }
        let failure = try XCTUnwrap(error as? ScreenSaverPublishFailure)
        XCTAssertEqual(failure.state.failure?.code, .committedThenFailed)
        let publication = try XCTUnwrap(failure.underlying as? ScreenSaverPublicationFailure)
        XCTAssertTrue(publication.errors[0].localizedDescription.contains("receipt write denied"))
        let current = try await f.store.current()
        XCTAssertNotNil(current?.generationID)
        XCTAssertEqual(publisher.state.published, current)
        XCTAssertEqual(publisher.state.phase, .failed)
        let restarted = try await f.makePublisher()
        XCTAssertEqual(restarted.state.published, current, "Restart reads current.json, not a stale app receipt")
    }

    func testSourceRemovalKeepsLastPublicationUntilExplicitDisableAndReaderExit() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await f.makePublisher()
        let old = try await publisher.request(library: f.library, settings: f.settings).value
        let selected = try await f.store.acquireCurrent()
        let lease = try XCTUnwrap(selected)
        addTeardownBlock { try await lease.close() }
        var missing = f.library; missing.media = []; missing.playlists = []
        _ = try await screenSaverFailure { try await publisher.request(library: missing, settings: f.settings).value }
        XCTAssertEqual(publisher.state.phase, .sourceInvalid)
        XCTAssertEqual(publisher.state.published, old)
        let disabled = try await publisher.disable().value
        XCTAssertNil(disabled?.generationID)
        XCTAssertEqual(publisher.state.phase, .unconfigured)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.directory.path))
        let newReader = try await f.store.acquireCurrent()
        XCTAssertNil(newReader)
        try await lease.close()
        let cleanup = try await f.store.collectGarbage()
        XCTAssertTrue(cleanup.removed.contains(lease.manifest.generationID))
    }
}
