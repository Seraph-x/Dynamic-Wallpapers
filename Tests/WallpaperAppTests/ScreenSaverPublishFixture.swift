import XCTest
import Foundation
import UniformTypeIdentifiers
import WallpaperCore
import WallpaperNative
import ScreenSaverCore
@testable import WallpaperApp

@MainActor
final class ScreenSaverPublishFixture {
    let directory: URL
    let store: ScreenSaverSnapshotStore
    let settingsURL: URL
    let item: MediaItem
    let library: Library
    let settings: ScreenSaverSettings
    private var publishers: [ScreenSaverPublisher] = []

    private init(directory: URL, store: ScreenSaverSnapshotStore, item: MediaItem) {
        self.directory = directory; self.store = store; self.item = item
        settingsURL = directory.appendingPathComponent("screensaver-settings.json")
        var library = Library()
        library.media = [item]
        library.playlists = [Playlist(name: "Screen saver fixture", entries: [
            PlaylistEntry(mediaID: item.id, timing: EntryTiming(seconds: 2)),
            PlaylistEntry(mediaID: item.id, timing: EntryTiming(seconds: 3), audio: AudioSettings(volume: 0.4))
        ], mode: .shuffle, transition: 0.2)]
        self.library = library
        settings = ScreenSaverSettings(source: .playlist(library.playlists[0].id))
    }

    static func make(in test: XCTestCase) async throws -> ScreenSaverPublishFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screensaver-publisher-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try MediaTests.makeImage(type: UTType.png.identifier, frames: 1)
        let destination = directory.appendingPathComponent("source.png")
        try FileManager.default.moveItem(at: source, to: destination)
        let store = try ScreenSaverSnapshotStore(root: directory.appendingPathComponent("export"))
        _ = try await store.initialize()
        let fixture = ScreenSaverPublishFixture(directory: directory, store: store,
                                               item: try await NativeMediaProbe.inspect(destination))
        test.addTeardownBlock { @MainActor in
            var failures: [Error] = []
            for publisher in fixture.publishers {
                if case .failure(let error) = await publisher.beginShutdown().result { failures.append(error) }
            }
            do { try FileManager.default.removeItem(at: directory) }
            catch { failures.append(error) }
            if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
        }
        return fixture
    }

    func makeSettingsStore(operations: ScreenSaverSettingsOperations = .system) throws -> ScreenSaverSettingsStore {
        try ScreenSaverSettingsStore(url: settingsURL, exportRoot: store.paths.root, operations: operations)
    }

    func makePublisher(exportOperations: ScreenSaverExportOperations = .system,
                       settingsOperations: ScreenSaverSettingsOperations = .system,
                       storeOperations: ScreenSaverStoreOperations = .system) async throws -> ScreenSaverPublisher {
        let writer = try ScreenSaverSnapshotStore(root: store.paths.root, operations: storeOperations)
        let publisher = ScreenSaverPublisher(store: writer, settingsStore: try makeSettingsStore(operations: settingsOperations),
                                              builder: ScreenSaverExportBuilder(operations: exportOperations))
        try await publisher.load()
        publishers.append(publisher)
        return publisher
    }

    var sourceRevision: ScreenSaverSourceRevision {
        get throws {
            try ScreenSaverSourceRevision(projection: ScreenSaverProjection(library: library, source: settings.source!),
                                           settings: settings)
        }
    }
}

/// Pauses a real dependency operation. It deliberately does not treat cancellation as completion.
actor ScreenSaverTestGate {
    private var entered = false
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    func waitForArrival() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Screen saver test gate was not reached") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
func screenSaverFailure<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async throws -> Error {
    let result: Result<T, Error>
    do { result = .success(try await operation()) }
    catch { result = .failure(error) }
    switch result {
    case .failure(let error): return error
    case .success:
        XCTFail("Expected a visible failure", file: file, line: line)
        throw WallpaperError("Expected operation to fail")
    }
}
