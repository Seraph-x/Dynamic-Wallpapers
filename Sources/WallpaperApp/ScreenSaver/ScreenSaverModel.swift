import Combine
import Foundation
import ScreenSaverCore
import WallpaperCore

/// Owns application-side screen saver intent without changing desktop playback or the library.
@MainActor
final class ScreenSaverModel: ObservableObject {
    @Published private(set) var state: ScreenSaverPublishState
    @Published private(set) var startupFailure: ScreenSaverFailure?
    private let publisher: ScreenSaverPublisher
    let preview: ScreenSaverPreviewController
    private let initialize: (() async throws -> Void)?
    private var observation: AnyCancellable?
    private var startup: Task<Void, Error>?
    private var requests: [UUID: Task<ScreenSaverCurrentPointer?, Error>] = [:]
    private var library = Library.empty
    private var libraryLoaded = false
    private var ready: Bool
    private var pendingSettings: ScreenSaverSettings?
    private var closed = false
    private var sourceVersion = 0
    private var intentVersion = 0
    private(set) var publicationRequestCount = 0

    var settings: ScreenSaverSettings { pendingSettings ?? state.target?.settings ?? ScreenSaverSettings() }
    var exportRoot: URL { publisher.exportRoot }
    var hasActiveWork: Bool { !requests.isEmpty || publisher.hasActiveWork }

    init(publisher: ScreenSaverPublisher, initialize: (() async throws -> Void)? = nil) {
        self.publisher = publisher
        preview = ScreenSaverPreviewController(root: publisher.exportRoot)
        self.initialize = initialize
        ready = initialize == nil
        state = publisher.state
        observation = publisher.$state.sink { [weak self] state in self?.state = state }
    }

    static func makeDefault(directory: URL) throws -> ScreenSaverModel {
        let export = directory.appendingPathComponent("ScreenSaverExport", isDirectory: true)
        let store = try ScreenSaverSnapshotStore(root: export)
        let settingsStore = try ScreenSaverSettingsStore(
            url: directory.appendingPathComponent("screensaver-settings.json"), exportRoot: export)
        return ScreenSaverModel(publisher: ScreenSaverPublisher(store: store, settingsStore: settingsStore),
                                initialize: { _ = try await store.initialize() })
    }

    func attach(library: Library, loaded: Bool) {
        self.library = library
        libraryLoaded = loaded
    }

    func start() {
        guard startup == nil, !closed else { return }
        startup = Task { @MainActor in
            do {
                try await initialize?()
                try await publisher.load()
                ready = true
                guard !closed else { return }
                if libraryLoaded, pendingSettings == nil,
                   settings.source != nil || state.phase == .pending { _ = update(settings) }
            } catch {
                startupFailure = ScreenSaverAppFailure.capture(error, phase: .load)
                throw error
            }
        }
    }

    @discardableResult
    func update(_ settings: ScreenSaverSettings, force: Bool = false) -> Task<ScreenSaverCurrentPointer?, Error> {
        intentVersion += 1
        let intent = intentVersion
        pendingSettings = settings
        let input = library
        let version = sourceVersion
        let id = UUID()
        let publication = ready && libraryLoaded && !closed
            ? requestPublication(library: input, settings: settings, force: force) : nil
        let task = Task { @MainActor in
            defer {
                requests.removeValue(forKey: id)
                if intentVersion == intent { pendingSettings = nil }
            }
            if let startup { try await startup.value }
            guard !closed else { throw ScreenSaverFailure(code: .applicationClosing(.configuration)) }
            guard libraryLoaded else { throw ScreenSaverFailure(code: .settingsUnavailable) }
            guard version == sourceVersion, intent == intentVersion else { throw CancellationError() }
            return try await (publication ?? requestPublication(library: input, settings: settings, force: force)).value
        }
        requests[id] = task
        return task
    }

    private func requestPublication(library: Library, settings: ScreenSaverSettings,
                                    force: Bool) -> Task<ScreenSaverCurrentPointer?, Error> {
        publicationRequestCount += 1
        let releasePreview = { [preview] in try await preview.stop().value }
        if settings.source == nil {
            return publisher.disable(settings: settings, beforePublication: releasePreview)
        }
        return publisher.request(library: library, settings: settings, force: force,
                                 beforePublication: releasePreview)
    }

    func libraryDidCommit(_ committed: Library, previous: Library, forceRevalidate: Bool = false) {
        library = committed
        let current = settings
        guard let source = current.source else { return }
        let before = revision(for: previous, settings: current)
        let after = revision(for: committed, settings: current)
        guard forceRevalidate || before != after else { return }
        sourceVersion += 1
        intentVersion += 1
        if after != nil { _ = update(current) }
        else {
            pendingSettings = nil
            let reason = Result { try ScreenSaverProjection(library: committed, source: source) }
            if case .failure(let error) = reason { publisher.sourceDidBecomeInvalid(error) }
        }
    }

    private func revision(for library: Library, settings: ScreenSaverSettings) -> ScreenSaverSourceRevision? {
        guard let source = settings.source,
              let projection = try? ScreenSaverProjection(library: library, source: source) else { return nil }
        return try? ScreenSaverSourceRevision(projection: projection, settings: settings)
    }

    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        publisher.beginRemovingMedia(ids)
    }

    func withLibraryCommitLock<T>(_ operation: () throws -> T) throws -> T {
        guard publisher.hasActiveWork else { return try operation() }
        let lock = try ScreenSaverFileLock.acquire(root: exportRoot, relativePath: ".catalog.lock",
                                                  mode: .exclusive, nonBlocking: false)
        return try lock.using(operation)
    }

    func waitForIdle() async {
        for request in Array(requests.values) { _ = await request.result }
    }

    func beginShutdown() -> Task<Void, Error> {
        closed = true
        let closing = publisher.beginShutdown()
        let previewClosing = preview.beginShutdown()
        let pending = Array(requests.values)
        return Task { @MainActor in
            _ = await startup?.result
            for request in pending { _ = await request.result }
            var failures: [Error] = []
            if case .failure(let error) = await previewClosing.result { failures.append(error) }
            if case .failure(let error) = await closing.result { failures.append(error) }
            if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
        }
    }
}
