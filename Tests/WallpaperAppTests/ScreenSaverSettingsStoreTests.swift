import XCTest
import Darwin
import WallpaperCore
import ScreenSaverCore
@testable import WallpaperApp

@MainActor
final class ScreenSaverSettingsStoreTests: XCTestCase {
    func testMissingSettingsRemainUnconfiguredAndSaveDoesNotTouchLibrary() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let settings = try f.makeSettingsStore()
        let initial = try await settings.load()
        XCTAssertNil(initial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.settingsURL.path))
        let libraryURL = f.directory.appendingPathComponent("library.json")
        let before = try JSONEncoder().encode(f.library)
        try before.write(to: libraryURL)
        let saved = try await settings.save(f.settings, sourceRevision: f.sourceRevision, replacing: nil)
        let loaded = try await settings.load()
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(try ScreenSaverSettings.read(from: f.settingsURL), f.settings)
        XCTAssertEqual(try Data(contentsOf: libraryURL), before)
        let current = try await f.store.current()
        XCTAssertNil(current, "Saving settings is not a publication")
    }

    func testUnchangedTargetKeepsRevisionAndStaleIndependentWriterCannotOverwrite() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let first = try f.makeSettingsStore(), second = try f.makeSettingsStore()
        let saved = try await first.save(f.settings, sourceRevision: f.sourceRevision, replacing: nil)
        let same = try await first.save(f.settings, sourceRevision: f.sourceRevision, replacing: saved.revision)
        XCTAssertEqual(same, saved)
        let changed = ScreenSaverSettings(source: f.settings.source, isMuted: false, fit: .fit)
        let projection = try ScreenSaverProjection(library: f.library, source: changed.source!)
        let newer = try await second.save(changed,
            sourceRevision: ScreenSaverSourceRevision(projection: projection, settings: changed), replacing: saved.revision)
        XCTAssertNotEqual(newer.revision, saved.revision)
        let bytes = try Data(contentsOf: f.settingsURL)
        _ = try await screenSaverFailure {
            try await first.save(f.settings, sourceRevision: f.sourceRevision, replacing: saved.revision)
        }
        XCTAssertEqual(try Data(contentsOf: f.settingsURL), bytes)
    }

    func testCorruptUnknownAndNonRegularSettingsAreNeverReplaced() async throws {
        for content in [Data("broken".utf8), Data("{\"schemaVersion\":900}".utf8)] {
            let f = try await ScreenSaverPublishFixture.make(in: self)
            try content.write(to: f.settingsURL)
            let settings = try f.makeSettingsStore()
            _ = try await screenSaverFailure { try await settings.load() }
            _ = try await screenSaverFailure { try await settings.save(f.settings, sourceRevision: f.sourceRevision, replacing: nil) }
            XCTAssertEqual(try Data(contentsOf: f.settingsURL), content)
        }
        let f = try await ScreenSaverPublishFixture.make(in: self)
        XCTAssertEqual(mkfifo(f.settingsURL.path, 0o600), 0)
        _ = try await screenSaverFailure { try await f.makeSettingsStore().load() }
        try FileManager.default.removeItem(at: f.settingsURL)
        try FileManager.default.createSymbolicLink(at: f.settingsURL, withDestinationURL: f.item.url)
        _ = try await screenSaverFailure { try await f.makeSettingsStore().load() }
    }

    func testFailedSettingsWritePreservesExactPreviousTarget() async throws {
        let f = try await ScreenSaverPublishFixture.make(in: self)
        let saved = try await f.makeSettingsStore().save(f.settings, sourceRevision: f.sourceRevision, replacing: nil)
        let bytes = try Data(contentsOf: f.settingsURL)
        var operations = ScreenSaverSettingsOperations.system
        operations.replaceDocument = { _, _ in throw POSIXError(.ENOSPC) }
        let failing = try f.makeSettingsStore(operations: operations)
        _ = try await screenSaverFailure {
            try await failing.save(f.settings.selecting(nil), sourceRevision: nil, replacing: saved.revision)
        }
        XCTAssertEqual(try Data(contentsOf: f.settingsURL), bytes)
    }
}
