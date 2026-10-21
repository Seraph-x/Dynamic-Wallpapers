import ScreenSaverCore
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class ScreenSaverRemovalTests: XCTestCase {
    func testSourceRemovalWaitsForActiveScreenSaverReaderAndKeepsOldPublication() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let initial = try await fixture.makePublisher()
        _ = try await initial.request(library: fixture.library, settings: fixture.settings).value
        let previous = try await fixture.store.current()
        let gate = ScreenSaverTestGate()
        let real = ScreenSaverExportOperations.system
        var operations = real
        operations.copy = { input, destination in
            await gate.pause()
            return try await real.copy(input, destination)
        }
        let publisher = try await fixture.makePublisher(exportOperations: operations)
        let screenSaver = ScreenSaverModel(publisher: publisher)
        let managedFiles = ManagedMediaStore(directory: fixture.directory.appendingPathComponent("Media"))
        let copy = try await managedFiles.stage(source: .file(fixture.item.url))
        try await managedFiles.commit(copy)
        let managedItem = copy.item(from: fixture.item)
        var library = fixture.library
        library.media = [managedItem]
        library.playlists[0].entries = library.playlists[0].entries.map {
            PlaylistEntry(id: $0.id, mediaID: managedItem.id, timing: $0.timing, audio: $0.audio)
        }
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(library)
        let model = AppModel(store: store, managedImport: ManagedMediaImport(files: managedFiles), screenSaver: screenSaver)

        let publishing = screenSaver.update(fixture.settings, force: true)
        try await gate.waitForArrival()
        model.removeMedia(managedItem.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedItem.url.path))
        await gate.release()
        _ = await publishing.result
        await model.waitForMediaRemovals()

        let current = try await fixture.store.current()
        XCTAssertEqual(current, previous,
                       "Deleting the source must preserve the last complete screen saver generation")
        XCTAssertEqual(screenSaver.state.phase, .sourceInvalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedItem.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.item.url.path))
        try await model.shutdownAndWait()
    }

    func testShutdownWaitsForActiveScreenSaverReader() async throws {
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
        let publishing = screenSaver.update(fixture.settings, force: true)
        try await gate.waitForArrival()

        var finished = false
        let started = expectation(description: "shutdown entered")
        let shutdown = Task { @MainActor in
            started.fulfill()
            try await model.shutdownAndWait()
            finished = true
        }
        await fulfillment(of: [started], timeout: 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished)
        XCTAssertTrue(screenSaver.hasActiveWork)
        await gate.release()
        _ = await publishing.result
        try await shutdown.value
        XCTAssertFalse(screenSaver.hasActiveWork)
    }
}
