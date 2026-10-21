import Foundation
import WallpaperCore

/// Separates visible commitment from resource release; neither failure is a successful no-op.
enum PlaybackTransitionResult {
    case displayed
    case displayedWithReleaseFailure(Error)
    case notDisplayed(Error)

    var didDisplay: Bool {
        if case .notDisplayed = self { return false }
        return true
    }
    var error: Error? {
        switch self {
        case .displayed: return nil
        case .displayedWithReleaseFailure(let error), .notDisplayed(let error): return error
        }
    }
}

@MainActor
protocol PlaybackEndpoint: AnyObject, Sendable {
    func prepare(item: MediaItem, fit: ContentFit, entry: PlaylistEntry) async throws
    func updateAudio(_ settings: [UUID: AudioSettings])
    func transition(duration: Double, paused: Bool) async -> PlaybackTransitionResult
    /// A failed close remains observable for as long as its backend retains resources.
    var releaseFailure: Error? { get }
    func discardPreparation()
    func setPaused(_ paused: Bool)
    func prepareToResume(requestID: UUID) async throws
    func cancelResumePreparation(requestID: UUID) async throws
}

@MainActor
final class PlaybackSession {
    private struct Request { let entryID: UUID?; let automatic: Bool }
    private struct Prepared {
        let id: UUID
        let proposal: PlaybackProposal
        let item: MediaItem
        let entry: PlaylistEntry
        let sourceVersion: Result<String, WallpaperError>
    }
    private var content: PlaybackContent
    private var media: [MediaItem]
    private var audioByEntry: [UUID: AudioSettings]
    private let endpoints: [any PlaybackEndpoint]
    private let fit: ContentFit
    private let autoAdvance: Bool
    private let sourceVersions = SystemWallpaperSourceVersionReader()
    private let onCommit: (UUID) -> Void
    private let onStatus: (String) -> Void
    private let onError: (Error) -> Void
    private var cursor: PlaylistCursor
    // A restored cursor selects the first item; it does not prove this session displayed it.
    private var hasDisplayedCurrent = false
    private var gate = TransitionGate()
    private var queued: (UUID, Request)?
    private var prepared: Prepared?
    private var preparationTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    private var dueTask: Task<Void, Never>?
    private var clock: PlaybackClock?
    private var paused = false
    private var requestedPaused = false
    private var previewSuspended = false
    private var shouldPause: Bool { requestedPaused || previewSuspended }
    private var resumeGeneration = UUID()
    private var resumeTask: Task<Void, Never>?
    private var stopped = false
    var currentEntryID: UUID? { cursor.current }
    var isTransitioning: Bool { gate.transitioning != nil }
    var canAdvance: Bool { content.allowsNext && !content.entries.isEmpty }
    var referencedMediaIDs: Set<UUID> { Set(content.entries.map(\.mediaID) + [prepared?.item.id].compactMap { $0 }) }
    var onWallpaperDisplayed: ((MediaItem, Result<String, WallpaperError>) -> Void)?

    convenience init(playlist: Playlist, media: [MediaItem], endpoints: [any PlaybackEndpoint], fit: ContentFit,
         current: UUID? = nil, autoAdvance: Bool = true,
         onCommit: @escaping (UUID) -> Void, onStatus: @escaping (String) -> Void,
         onError: @escaping (Error) -> Void) {
        self.init(content: PlaybackContent(playlist: playlist), media: media, endpoints: endpoints, fit: fit,
                  current: current, autoAdvance: autoAdvance, onCommit: onCommit, onStatus: onStatus, onError: onError)
    }

    init(content: PlaybackContent, media: [MediaItem], endpoints: [any PlaybackEndpoint], fit: ContentFit,
         current: UUID? = nil, autoAdvance: Bool = true,
         onCommit: @escaping (UUID) -> Void, onStatus: @escaping (String) -> Void,
         onError: @escaping (Error) -> Void) {
        self.content = content; self.media = media; self.endpoints = endpoints; self.fit = fit
        audioByEntry = Dictionary(uniqueKeysWithValues: content.entries.map { ($0.id, $0.audio) })
        self.autoAdvance = autoAdvance; self.onCommit = onCommit; self.onStatus = onStatus; self.onError = onError
        cursor = PlaylistCursor(current: current)
    }

    func start() { request(Request(entryID: cursor.current, automatic: false)) }
    func next() {
        guard canAdvance else { return }
        request(Request(entryID: nil, automatic: false))
    }

    func setPaused(_ value: Bool) {
        if !value, releaseFailure != nil {
            if !isTransitioning { onStatus(releaseFailureStatus) }
            return
        }
        guard !stopped else { return }
        requestedPaused = value
        applyPauseIntent()
    }

    /// Temporary preview ownership must not overwrite the user's or a failure's pause intent.
    func setPreviewSuspended(_ value: Bool) {
        guard !stopped, previewSuspended != value else { return }
        previewSuspended = value
        applyPauseIntent()
    }

    private func applyPauseIntent() {
        if shouldPause {
            resumeGeneration = UUID()
            resumeTask?.cancel()
            paused = true
            endpoints.forEach { $0.setPaused(true) }
            clock?.pause(now: now); scheduleTask?.cancel(); dueTask?.cancel()
            if !isTransitioning { cancelPreparation() }
        } else {
            startResumeIfPossible()
        }
    }

    private func startResumeIfPossible() {
        guard paused, !shouldPause, !stopped, !isTransitioning, gate.preparing == nil, resumeTask == nil else { return }
        if releaseFailure != nil { onStatus(releaseFailureStatus); return }
        guard hasDisplayedCurrent else {
            paused = false
            if !content.entries.isEmpty { start() }
            return
        }
        let id = UUID()
        resumeGeneration = id
        onStatus("恢复中，等待全部显示器就绪")
        resumeTask = Task { [self] in
            defer {
                resumeTask = nil
                if resumeGeneration != id { startResumeIfPossible() }
            }
            do {
                let prepareEndpoint: @MainActor @Sendable (any PlaybackEndpoint) async throws -> Void = {
                    try await $0.prepareToResume(requestID: id)
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for endpoint in endpoints {
                        group.addTask { try await prepareEndpoint(endpoint) }
                    }
                    while try await group.next() != nil { }
                }
                try Task.checkCancellation()
                guard resumeGeneration == id, !shouldPause, !stopped else { throw CancellationError() }
                refreshAudio()
                for endpoint in endpoints {
                    guard resumeGeneration == id, !shouldPause, !stopped else { throw CancellationError() }
                    endpoint.setPaused(false)
                }
                guard resumeGeneration == id, !shouldPause, !stopped else { throw CancellationError() }
                paused = false
                clock?.resume(now: now)
                if let prepared { scheduleCommit(prepared) } else { scheduleNext() }
                onStatus("正在播放")
            } catch {
                var cleanupFailure: Error?
                do { try await revokeResume(id) } catch { cleanupFailure = error }
                if let cleanupFailure {
                    onStatus(releaseFailureStatus)
                    onError(cleanupFailure)
                } else if !(error is CancellationError), resumeGeneration == id, !stopped {
                    requestedPaused = true
                    onStatus("恢复失败，保留暂停画面")
                    onError(error)
                }
            }
        }
    }

    private func revokeResume(_ id: UUID) async throws {
        let tasks = endpoints.map { endpoint in
            Task { @MainActor in try await endpoint.cancelResumePreparation(requestID: id) }
        }
        try await PlaybackCloseBarrier.wait(for: tasks)
    }

    func update(playlist: Playlist, media: [MediaItem]) {
        update(content: PlaybackContent(playlist: playlist), media: media)
    }

    func update(content: PlaybackContent, media: [MediaItem]) {
        guard self.content != content || self.media != media else { return }
        let requiresRescheduling = !self.content.hasSameSchedule(as: content) || self.media != media
        self.content = content; self.media = media
        updateAudio(entries: content.entries)
        guard requiresRescheduling else { return }
        if !isTransitioning, releaseFailure != nil { onStatus(releaseFailureStatus); return }
        if let displayed = isTransitioning ? cursor.pending?.entryID : cursor.current,
           let entry = content.entries.first(where: { $0.id == displayed }),
           let item = media.first(where: { $0.id == entry.mediaID }) {
            clock?.updateDuration(entry.timing.duration(mediaDuration: item.duration))
        }
        if isTransitioning {
            // Finish the visible transaction before applying an edited queue.
            if !content.entries.isEmpty, let current = cursor.pending?.entryID,
               !content.entries.contains(where: { $0.id == current }) { request(Request(entryID: nil, automatic: false)) }
            return
        }
        cancelPreparation()
        if let current = cursor.current, content.entries.contains(where: { $0.id == current }) { scheduleNext() }
        else if !content.entries.isEmpty { request(Request(entryID: nil, automatic: false)) }
        else { onStatus("播放列表为空，保留当前画面") }
    }

    func updateAudio(entries: [PlaylistEntry]) {
        audioByEntry = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.audio) })
        refreshAudio()
    }

    private func refreshAudio() {
        endpoints.forEach { $0.updateAudio(audioByEntry) }
    }

    func stop(pauseDisplay: Bool = true) {
        stopped = true
        resumeGeneration = UUID(); resumeTask?.cancel()
        cancelPreparation()
        if pauseDisplay { endpoints.forEach { $0.setPaused(true) } }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var releaseFailure: Error? { endpoints.lazy.compactMap { $0.releaseFailure }.first }
    private var releaseFailureStatus: String { "播放器资源释放失败，已暂停" }

    private func request(_ request: Request) {
        guard !stopped else { return }
        if resumeTask != nil { resumeGeneration = UUID(); resumeTask?.cancel() }
        if !isTransitioning, releaseFailure != nil {
            setPaused(true)
            onStatus(releaseFailureStatus)
            return
        }
        let id = UUID()
        guard gate.request(id) else { queued = (id, request); return }
        begin(id: id, request: request)
    }

    private func begin(id: UUID, request: Request) {
        preparationTask?.cancel(); scheduleTask?.cancel(); dueTask?.cancel()
        prepared = nil
        endpoints.forEach { $0.discardPreparation() }
        do {
            let proposal: PlaybackProposal
            if let entryID = request.entryID { proposal = cursor.prepare(entryID: entryID) }
            else { proposal = try cursor.prepare(ids: content.entries.map(\.id), mode: content.mode) }
            guard let entry = content.entries.first(where: { $0.id == proposal.entryID }),
                  let item = media.first(where: { $0.id == entry.mediaID }), !endpoints.isEmpty else {
                throw WallpaperError("找不到待播素材或目标显示器。")
            }
            onStatus("准备中 · \(item.name)")
            let drainingResume = resumeTask
            preparationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    await drainingResume?.value
                    try Task.checkCancellation()
                    let version = try await self.prepareVersioned(item, entry: entry)
                    try Task.checkCancellation()
                    guard self.gate.preparing == id, !self.stopped else { return }
                    self.refreshAudio()
                    let prepared = Prepared(id: id, proposal: proposal, item: item, entry: entry, sourceVersion: version)
                    self.prepared = prepared
                    if request.automatic { self.scheduleCommit(prepared) }
                    else { await self.commit(prepared) }
                } catch is CancellationError { /* A newer request owns preparation. */ }
                catch {
                    guard self.gate.preparing == id, !self.stopped else { return }
                    self.cancelPreparation()
                    self.onStatus("切换失败，保留当前画面")
                    self.onError(error)
                }
            }
        } catch {
            gate.fail(id); cursor.cancel()
            onStatus("切换失败，保留当前画面"); onError(error)
        }
    }

    private func prepareAll(_ item: MediaItem, entry: PlaylistEntry) async throws {
        let prepareEndpoint: @MainActor @Sendable (any PlaybackEndpoint) async throws -> Void = {
            [fit] endpoint in
            try await endpoint.prepare(item: item, fit: fit, entry: entry)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for endpoint in endpoints { group.addTask { try await prepareEndpoint(endpoint) } }
            // Surface the first failure so the group cancels other in-flight decoders.
            while try await group.next() != nil { }
        }
    }

    private func prepareVersioned(_ item: MediaItem, entry: PlaylistEntry) async throws -> Result<String, WallpaperError> {
        // The two samples enclose decoding; sampling only when sync is enabled could mislabel old pixels.
        let before = try await sourceVersions.record(item)
        try Task.checkCancellation()
        try await prepareAll(item, entry: entry)
        try Task.checkCancellation()
        if case .failure = before { return before }
        let after = try await sourceVersions.record(item)
        try Task.checkCancellation()
        if case .failure = after { return after }
        return before == after ? before : .failure(SystemWallpaperSourceVersionReader.changedSource)
    }

    private func scheduleCommit(_ prepared: Prepared) {
        guard !paused else { return }
        dueTask?.cancel()
        let delay = clock?.remaining(now: now) ?? 0
        dueTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                await self?.commit(prepared)
            } catch is CancellationError { /* Pause or new selection. */ }
            catch { self?.onError(error) }
        }
    }

    private func commit(_ prepared: Prepared) async {
        guard !stopped, gate.beginTransition(prepared.id) else { return }
        self.prepared = nil
        onStatus("切换中 · \(prepared.item.name)")
        clock = PlaybackClock(duration: prepared.entry.timing.duration(mediaDuration: prepared.item.duration), now: now)
        if paused { clock?.pause(now: now) }
        let results = await transitionAll()
        guard !stopped else { return }
        let allDisplayed = results.allSatisfy(\.didDisplay)
        if allDisplayed, cursor.commit(prepared.proposal) {
            hasDisplayedCurrent = true
            onWallpaperDisplayed?(prepared.item, prepared.sourceVersion)
            if content.entries.contains(where: { $0.id == prepared.entry.id }) { onCommit(prepared.entry.id) }
        } else { cursor.cancel() }
        let nextID = gate.finish(prepared.id)
        let failures = results.compactMap(\.error)
        if !failures.isEmpty {
            queued = nil
            if let nextID { gate.fail(nextID) }
            setPaused(true)
            endpoints.forEach { $0.discardPreparation() }
            onStatus(allDisplayed ? releaseFailureStatus : "切换未完成，已暂停")
            failures.forEach(onError)
            return
        }
        onStatus(content.entries.isEmpty ? "播放列表为空，保留当前画面" : "正在播放 · \(prepared.item.name)")
        if content.entries.isEmpty {
            if let nextID { gate.fail(nextID) }
            queued = nil
            return
        }
        if let queued, queued.0 == nextID {
            self.queued = nil; begin(id: queued.0, request: queued.1)
        } else { startResumeIfPossible(); scheduleNext() }
    }

    private func transitionAll() async -> [PlaybackTransitionResult] {
        let duration = content.transition
        let transitionEndpoint: @MainActor @Sendable (any PlaybackEndpoint) async -> PlaybackTransitionResult = {
            [self] endpoint in
            await endpoint.transition(duration: duration, paused: paused)
        }
        return await withTaskGroup(of: PlaybackTransitionResult.self, returning: [PlaybackTransitionResult].self) { group in
            for endpoint in endpoints {
                group.addTask { await transitionEndpoint(endpoint) }
            }
            var results: [PlaybackTransitionResult] = []
            // A release failure must not cancel another screen's visible transaction.
            for await result in group { results.append(result) }
            return results
        }
    }

    private func scheduleNext() {
        scheduleTask?.cancel()
        guard autoAdvance, content.allowsNext, !paused, !stopped, !isTransitioning,
              content.mode != .repeatOne, content.entries.count > 1, let clock else { return }
        let remaining = clock.remaining(now: now)
        // Keep dual decoding short: preload at most two seconds before the deadline.
        let lead = min(2, remaining * 0.2)
        scheduleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, remaining - lead)))
                try Task.checkCancellation()
                self?.request(Request(entryID: nil, automatic: true))
            } catch is CancellationError { /* Timeline changed or paused. */ }
            catch { self?.onError(error) }
        }
    }

    private func cancelPreparation() {
        preparationTask?.cancel(); scheduleTask?.cancel(); dueTask?.cancel()
        preparationTask = nil; scheduleTask = nil; dueTask = nil
        if let id = gate.preparing { gate.fail(id) }
        prepared = nil; cursor.cancel()
        if !isTransitioning { endpoints.forEach { $0.discardPreparation() } }
    }
}
