import AppKit
import ScreenSaverCore
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class ScreenSaverAppModelTests: XCTestCase {
    func testStartupCapturesStructuredFailureAndPreservesThrownError() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await fixture.makePublisher()
        let original = CocoaError(.fileReadNoPermission)
        let model = ScreenSaverModel(publisher: publisher, initialize: { throw original })
        model.attach(library: fixture.library, loaded: true)

        model.start()
        let result = await model.update(fixture.settings).result

        guard case .failure(let error) = result else { return XCTFail("Expected startup error") }
        XCTAssertEqual((error as NSError).code, (original as NSError).code)
        XCTAssertEqual(model.startupFailure?.code, .unexpected)
        XCTAssertEqual(model.startupFailure?.diagnostic?.code, (original as NSError).code)
        try await model.beginShutdown().value
    }

    func testSettingsWithoutSelectedSourceArePersisted() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await fixture.makePublisher()
        let model = ScreenSaverModel(publisher: publisher)
        model.attach(library: fixture.library, loaded: true)
        let settings = ScreenSaverSettings(isMuted: false, fit: .fit)

        _ = try await model.update(settings).value

        XCTAssertEqual(model.settings, settings)
        XCTAssertEqual(model.state.target?.settings, settings)
        let stored = try await fixture.makeSettingsStore().load()
        XCTAssertEqual(stored?.settings, settings)
        try await model.beginShutdown().value
    }

    func testStartupRetriesDisableAfterSettingsCommitButBeforePointerCommit() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let original = try await fixture.makePublisher()
        let published = try await original.request(library: fixture.library, settings: fixture.settings).value
        let store = try fixture.makeSettingsStore()
        let loaded = try await store.load()
        let previous = try XCTUnwrap(loaded)
        let disabled = ScreenSaverSettings(isMuted: false, fit: .fit)
        _ = try await store.save(disabled, sourceRevision: nil, replacing: previous.revision)
        let restarted = try await fixture.makePublisher()
        XCTAssertEqual(restarted.state.phase, .pending)
        XCTAssertEqual(restarted.state.published, published)
        let model = ScreenSaverModel(publisher: restarted)
        model.attach(library: fixture.library, loaded: true)

        model.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while model.state.phase != .unconfigured && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.state.phase, .unconfigured)
        XCTAssertEqual(model.settings, disabled)
        let current = try await fixture.store.current()
        XCTAssertNil(current?.generationID)
        try await model.beginShutdown().value
    }

    func testScreenSaverSettingsAndPublicationLeaveDesktopAndLibraryUntouched() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await fixture.makePublisher()
        let screenSaver = ScreenSaverModel(publisher: publisher)
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        guard let displayID = NSScreen.screens.first?.wallpaperID else {
            throw XCTSkip("Current test host has no readable display identity for a real desktop window")
        }
        var displayedLibrary = fixture.library
        displayedLibrary.displays = [DisplayBinding(id: displayID, playlistID: fixture.library.playlists[0].id)]
        try store.save(displayedLibrary)
        let model = AppModel(store: store, screenSaver: screenSaver)
        model.togglePause()
        let deadline = ContinuousClock.now + .seconds(2)
        while model.desktopIdentity.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.desktopIdentity.isEmpty, "The assertion must cover a real desktop window")
        let library = model.library
        let bytes = try Data(contentsOf: store.url)
        let desktop = model.desktopIdentity
        let displays = model.library.displays
        let selection = (model.selectedMediaID, model.selectedEntryID)

        _ = try await screenSaver.update(fixture.settings).value

        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        XCTAssertEqual(model.library, library)
        XCTAssertEqual(model.library.displays, displays)
        XCTAssertEqual(model.selectedMediaID, selection.0)
        XCTAssertEqual(model.selectedEntryID, selection.1)
        XCTAssertTrue(model.userPaused)
        XCTAssertEqual(model.desktopIdentity, desktop)
        XCTAssertEqual(screenSaver.state.phase, .published)
        try await model.shutdownAndWait()
    }

    func testOnlySuccessfulRelevantLibraryCommitsRequestPublication() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await fixture.makePublisher()
        let screenSaver = ScreenSaverModel(publisher: publisher)
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        _ = try await screenSaver.update(fixture.settings).value
        let initialRequests = screenSaver.publicationRequestCount

        XCTAssertTrue(model.mutate { $0.media[0].isFavorite.toggle() })
        await screenSaver.waitForIdle()
        XCTAssertEqual(screenSaver.publicationRequestCount, initialRequests,
                       "Favorite state is outside the selected screen saver projection")

        XCTAssertTrue(model.mutate { $0.playlists[0].name = "Updated source" })
        await screenSaver.waitForIdle()
        XCTAssertEqual(screenSaver.publicationRequestCount, initialRequests + 1)
        let published = screenSaver.state.published

        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        let before = model.library
        XCTAssertFalse(model.mutate { $0.playlists.removeAll() })
        await screenSaver.waitForIdle()
        XCTAssertEqual(model.library, before)
        XCTAssertEqual(screenSaver.publicationRequestCount, initialRequests + 1)
        XCTAssertEqual(screenSaver.state.published, published)
        try await model.shutdownAndWait()
    }

    func testUnreadableMainLibraryCannotWriteScreenSaverTargetFromEmptyMemory() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await fixture.makePublisher()
        let screenSaver = ScreenSaverModel(publisher: publisher)
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try Data("{broken".utf8).write(to: store.url)
        let model = AppModel(store: store, screenSaver: screenSaver)

        XCTAssertTrue(model.loadFailed)
        _ = await screenSaver.update(fixture.settings).result
        XCTAssertNil(publisher.state.target)
        XCTAssertEqual(screenSaver.publicationRequestCount, 0)
        let current = try await fixture.store.current()
        XCTAssertNil(current)
        try await model.shutdownAndWait()
    }

    func testExplicitUpdateDuringStartupDoesNotQueueAnOlderAutomaticUpdate() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = ScreenSaverPublisher(store: fixture.store, settingsStore: try fixture.makeSettingsStore())
        let gate = ScreenSaverTestGate()
        let screenSaver = ScreenSaverModel(publisher: publisher, initialize: { await gate.pause() })
        screenSaver.attach(library: fixture.library, loaded: true)
        screenSaver.start()

        try await gate.waitForArrival()
        let update = screenSaver.update(fixture.settings)
        await gate.release()
        _ = try await update.value
        await screenSaver.waitForIdle()

        XCTAssertEqual(screenSaver.publicationRequestCount, 1)
        XCTAssertEqual(screenSaver.state.phase, .published)
        try await screenSaver.beginShutdown().value
    }

    func testCommittedSourceEditImmediatelySupersedesAnInFlightPublication() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let gate = ScreenSaverTestGate()
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.copy = { input, destination in
            await gate.pause()
            return try await real.copy(input, destination)
        }
        let publisher = try await fixture.makePublisher(exportOperations: operations)
        let screenSaver = ScreenSaverModel(publisher: publisher)
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        let oldRequest = screenSaver.update(fixture.settings)
        try await gate.waitForArrival()

        XCTAssertTrue(model.mutate { $0.playlists[0].name = "New committed name" })
        XCTAssertEqual(publisher.state.phase, .pending)
        await gate.release()
        _ = await oldRequest.result
        await screenSaver.waitForIdle()

        XCTAssertEqual(publisher.state.projection?.name, "New committed name")
        XCTAssertEqual(publisher.state.phase, .published)
        try await model.shutdownAndWait()
    }

    func testLibrarySaveWaitsForScreenSaverCatalogTransaction() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let gate = ScreenSaverTestGate()
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.copy = { input, destination in
            await gate.pause()
            return try await real.copy(input, destination)
        }
        let publisher = try await fixture.makePublisher(exportOperations: operations)
        let screenSaver = ScreenSaverModel(publisher: publisher)
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        let oldRequest = screenSaver.update(fixture.settings)
        try await gate.waitForArrival()
        let original = try Data(contentsOf: store.url)
        let catalog = try ScreenSaverFileLock.acquire(root: fixture.store.paths.root,
            relativePath: ".catalog.lock", mode: .exclusive, nonBlocking: false)
        let started = AsyncStream<Void>.makeStream()
        let libraryURL = store.url
        let observer = Task.detached { () throws -> Data in
            var events = started.stream.makeAsyncIterator()
            guard await events.next() != nil else { throw WallpaperError("Mutation signal ended before delivery") }
            try await Task.sleep(for: .milliseconds(100))
            return try catalog.using { try Data(contentsOf: libraryURL) }
        }
        let mutation = Task { @MainActor in
            let result = model.mutate {
                $0.playlists[0].name = "Revised source"
                started.continuation.yield()
            }
            started.continuation.finish()
            return result
        }

        let whileLocked = try await observer.value
        let didMutate = await mutation.value
        await gate.release()
        _ = await oldRequest.result
        await screenSaver.waitForIdle()

        XCTAssertEqual(whileLocked, original, "The library and publication invalidation must share the catalog transaction")
        XCTAssertTrue(didMutate)
        XCTAssertEqual(screenSaver.state.projection?.name, "Revised source")
        try await model.shutdownAndWait()
    }

    func testResettingUnreadableLibraryInvalidatesPriorScreenSaverSource() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = try await fixture.makePublisher()
        let previous = try await publisher.request(library: fixture.library, settings: fixture.settings).value
        let screenSaver = ScreenSaverModel(publisher: publisher)
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try Data("{broken".utf8).write(to: store.url)
        let model = AppModel(store: store, screenSaver: screenSaver)
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(screenSaver.state.phase, .published)

        model.resetLibrary()

        XCTAssertFalse(model.loadFailed)
        XCTAssertEqual(screenSaver.state.phase, .sourceInvalid)
        XCTAssertEqual(screenSaver.state.published, previous)
        XCTAssertEqual(screenSaver.publicationRequestCount, 0)
        try await model.shutdownAndWait()
    }

    func testConcurrentWriterConflictRestoresActualPersistedSettings() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let initial = try await fixture.makePublisher()
        _ = try await initial.request(library: fixture.library, settings: fixture.settings).value
        let stale = try await fixture.makePublisher()
        let other = try await fixture.makePublisher()
        let latest = ScreenSaverSettings(source: .media(fixture.item.id))
        _ = try await other.request(library: fixture.library, settings: latest).value
        let model = ScreenSaverModel(publisher: stale)
        model.attach(library: fixture.library, loaded: true)

        let failed = ScreenSaverSettings(source: fixture.settings.source, isMuted: false)
        _ = await model.update(failed).result

        XCTAssertEqual(model.settings, latest)
        XCTAssertEqual(model.state.target?.settings, latest)
        try await model.beginShutdown().value
    }

    func testLatestSettingsIntentWinsWhenSeveralUpdatesWaitForStartup() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let publisher = ScreenSaverPublisher(store: fixture.store, settingsStore: try fixture.makeSettingsStore())
        let gate = ScreenSaverTestGate()
        let model = ScreenSaverModel(publisher: publisher, initialize: { await gate.pause() })
        model.attach(library: fixture.library, loaded: true)
        model.start()
        try await gate.waitForArrival()

        let previous = model.update(fixture.settings)
        let latest = ScreenSaverSettings(source: .media(fixture.item.id))
        let current = model.update(latest)
        await gate.release()
        _ = await previous.result
        _ = try await current.value

        XCTAssertEqual(model.settings, latest)
        let stored = try await fixture.makeSettingsStore().load()
        XCTAssertEqual(stored?.settings, latest)
        try await model.beginShutdown().value
    }
}
