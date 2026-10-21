import Combine
import Foundation
import ScreenSaverCore
import WallpaperCore

/// Application-owned serial publication and source-read barrier; unrelated to desktop playback.
@MainActor
final class ScreenSaverPublisher: ObservableObject {
    @Published private(set) var state = ScreenSaverPublishState()
    let exportRoot: URL
    private let worker: ScreenSaverPublishWorker
    private var latestID: UUID?
    private var jobs: [UUID: Job] = [:]
    private var tail: Task<ScreenSaverCurrentPointer?, Error>?
    private var removedMediaIDs: Set<UUID> = []
    private var retainedReads: [ObjectIdentifier: ScreenSaverSourceReleaseFailure] = [:]
    private var shutdown: Task<Void, Error>?
    private var loaded = false

    private final class Job {
        let id = UUID()
        let mediaIDs: Set<UUID>
        var task: Task<ScreenSaverCurrentPointer?, Error>?
        init(mediaIDs: Set<UUID>) { self.mediaIDs = mediaIDs }
    }

    var hasActiveWork: Bool { !jobs.isEmpty }

    init(store: ScreenSaverSnapshotStore, settingsStore: ScreenSaverSettingsStore,
         builder: ScreenSaverExportBuilder = ScreenSaverExportBuilder()) {
        exportRoot = store.paths.root
        worker = ScreenSaverPublishWorker(store: store, settingsStore: settingsStore, builder: builder)
    }

    /// The application explicitly initializes the export before loading this independent publisher.
    func load() async throws {
        guard jobs.isEmpty, shutdown == nil else { throw ScreenSaverFailure(code: .resourceReleaseFailed) }
        loaded = false
        do {
            state = try await worker.load()
            loaded = true
        } catch {
            state.phase = .failed; state.failure = ScreenSaverAppFailure.capture(error, phase: .load)
            state.currentVerified = false
            throw error
        }
    }

    @discardableResult
    func request(library: Library, settings: ScreenSaverSettings, force: Bool = false,
                 beforePublication: @escaping @MainActor () async throws -> Void = {}) -> Task<ScreenSaverCurrentPointer?, Error> {
        enqueue(.publish(library: library, settings: settings, force: force), beforePublication: beforePublication)
    }

    @discardableResult
    func disable() -> Task<ScreenSaverCurrentPointer?, Error> {
        disable(settings: (state.target?.settings ?? ScreenSaverSettings()).selecting(nil))
    }

    @discardableResult
    func disable(settings: ScreenSaverSettings,
                 beforePublication: @escaping @MainActor () async throws -> Void = {}) -> Task<ScreenSaverCurrentPointer?, Error> {
        return enqueue(.disable(settings: settings), beforePublication: beforePublication)
    }

    private func enqueue(_ action: ScreenSaverPublishAction,
                         beforePublication: @escaping @MainActor () async throws -> Void) -> Task<ScreenSaverCurrentPointer?, Error> {
        guard loaded, shutdown == nil else {
            let error = ScreenSaverFailure(code: shutdown == nil ? .settingsUnavailable : .applicationClosing(.publish))
            state.failure = error
            return Task { throw error }
        }
        for job in jobs.values { job.task?.cancel() }
        let job = Job(mediaIDs: action.mediaIDs)
        latestID = job.id
        state.phase = .pending; state.failure = nil
        let previous = tail
        jobs[job.id] = job
        let task = Task { @MainActor in
            // Predecessor failure is already observable on its own task/state. Serial scheduling waits
            // for real completion, not successful media decoding; retained release failures are checked below.
            if let previous { _ = await previous.result }
            defer { jobs.removeValue(forKey: job.id) }
            do {
                try Task.checkCancellation()
                guard latestID == job.id, shutdown == nil else { throw CancellationError() }
                if let removed = job.mediaIDs.intersection(removedMediaIDs).first {
                    throw ScreenSaverProjectionError.missingMedia(removed)
                }
                let failures = retainedReads.values.filter { job.mediaIDs.contains($0.mediaID) }
                if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
                try await beforePublication()
                try Task.checkCancellation()
                guard latestID == job.id, shutdown == nil else { throw CancellationError() }
                let result = try await worker.run(action) { [weak self] update in self?.receive(update, id: job.id) }
                receive(result, id: job.id)
                return result.published
            } catch {
                for failure in ScreenSaverSourceReleaseFailure.retained(in: error) {
                    retainedReads[failure.resourceID] = failure
                }
                if let failure = error as? ScreenSaverPublishFailure { receive(failure.state, id: job.id) }
                else if latestID == job.id {
                    state.phase = ScreenSaverPublishFailure.isCleanCancellation(error) ? .cancelled
                        : error is ScreenSaverProjectionError ? .sourceInvalid : .failed
                    state.failure = ScreenSaverAppFailure.capture(error, phase: .publish)
                }
                throw error
            }
        }
        job.task = task
        tail = task
        return task
    }

    private func receive(_ update: ScreenSaverPublishState, id: UUID) {
        if latestID == id { state = update }
        else {
            // Jobs run serially: this observation precedes the newer job's disk work. Preserve
            // commit history and loss of verification without replacing the newer target/phase.
            state.published = update.published
            state.currentVerified = update.currentVerified
        }
    }

    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        removedMediaIDs.formUnion(ids)
        let affected = jobs.values.filter { !$0.mediaIDs.isDisjoint(with: ids) }
        for job in affected {
            job.task?.cancel()
            if latestID == job.id {
                latestID = nil
                state.phase = .sourceInvalid
                state.failure = job.mediaIDs.intersection(ids).first.map {
                    ScreenSaverFailure(code: .sourceMissing(.media($0)))
                }
            }
        }
        let tasks = affected.compactMap(\.task)
        return Task { try await waitForRelease(tasks, mediaIDs: ids) }
    }

    func sourceDidBecomeInvalid(_ error: Error) {
        latestID = nil
        for job in jobs.values { job.task?.cancel() }
        state.phase = .sourceInvalid
        state.failure = ScreenSaverAppFailure.capture(error, phase: .publish)
    }

    func beginShutdown() -> Task<Void, Error> {
        if let shutdown { return shutdown }
        latestID = nil
        let tasks = jobs.values.compactMap(\.task)
        for task in tasks { task.cancel() }
        let task = Task { try await waitForRelease(tasks, mediaIDs: nil) }
        shutdown = task
        return task
    }

    private func waitForRelease(_ tasks: [Task<ScreenSaverCurrentPointer?, Error>], mediaIDs: Set<UUID>?) async throws {
        var failures: [Error] = []
        for task in tasks {
            if case .failure(let error) = await task.result, !ScreenSaverPublishFailure.isCleanCancellation(error) {
                failures.append(error)
            }
        }
        let reported = Set(failures.flatMap { ScreenSaverSourceReleaseFailure.retained(in: $0) }.map(\.resourceID))
        failures.append(contentsOf: retainedReads.values.filter {
            (mediaIDs?.contains($0.mediaID) ?? true) && !reported.contains($0.resourceID)
        })
        if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
    }
}
