import AppKit
import OSLog
import ScreenSaverCore
import WallpaperCore
import WallpaperNative

public struct ScreenSaverSessionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case stopped, preparing, playing, stopping, failed }
    public var phase: Phase = .stopped
    public var generationID: UUID?
    public var entryID: UUID?
    public var audio: ScreenSaverAudioPolicy?
    public var failure: ScreenSaverFailure?
}

public struct ScreenSaverSessionStart: Equatable {
    public let runID: UUID
    public let state: ScreenSaverSessionState
    public let created: Bool
}

@MainActor
public final class ScreenSaverSession {
    private static let logger = Logger(subsystem: "local.dynamicwallpaper.screensaver", category: "session")
    public typealias AccessFactory = @MainActor () throws -> any ScreenSaverDirectoryAccess
    public private(set) var state = ScreenSaverSessionState()
    public var onStateChange: ((ScreenSaverSessionState) -> Void)?
    public var onError: ((UUID, Error) -> Void)?
    private let view: NSView
    private let audioContext: ScreenSaverAudioContext
    private let makeAccess: AccessFactory
    private let makeSurface: ScreenSaverRenderer.SurfaceFactory
    private var active: Run?
    private var runs: [UUID: Run] = [:]
    private var visibleRunID: UUID?

    private final class Run {
        let id = UUID()
        let renderer: ScreenSaverRenderer
        var access: (any ScreenSaverDirectoryAccess)?
        var lease: ScreenSaverSnapshotLease?
        var work: Task<Void, Never>?
        var close: Task<Void, Error>?
        var closing = false
        var failure: Error?
        init(renderer: ScreenSaverRenderer) { self.renderer = renderer }
    }

    public init(view: NSView, audioContext: ScreenSaverAudioContext, access: @escaping AccessFactory,
                makeSurface: @escaping ScreenSaverRenderer.SurfaceFactory = { MediaSurface(size: $0, fit: $1) }) {
        self.view = view; self.audioContext = audioContext; makeAccess = access; self.makeSurface = makeSurface
    }

    @discardableResult
    public func start() -> ScreenSaverSessionStart {
        if let active { return ScreenSaverSessionStart(runID: active.id, state: state, created: false) }
        let run = Run(renderer: ScreenSaverRenderer(view: view, makeSurface: makeSurface))
        active = run; runs[run.id] = run; visibleRunID = run.id
        state = ScreenSaverSessionState(); state.phase = .preparing
        run.renderer.onError = { [weak self, weak run] error in
            guard let self, let run, self.active === run else { return }
            self.fail(error, run: run)
        }
        run.work = Task { [self] in
            do { try await play(run) }
            catch is CancellationError {
                if active === run { fail(CancellationError(), run: run) }
            }
            catch { fail(error, run: run) }
        }
        onStateChange?(state)
        return ScreenSaverSessionStart(runID: run.id, state: state, created: true)
    }

    /// Returns a real release barrier. An explicit repeated stop retries retained failed closes.
    @discardableResult
    public func stop() -> Task<Void, Error> {
        active = nil
        let tasks = Array(runs.values).map { beginClose($0) }
        return Task {
            var errors: [Error] = []
            for task in tasks { if case .failure(let error) = await task.result { errors.append(error) } }
            if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
        }
    }

    private func play(_ run: Run) async throws {
        try checkActive(run)
        let access = try makeAccess()
        run.access = access
        let reader = try ScreenSaverSnapshotReader(root: access.root, expectedExportID: access.expectedExportID)
        run.lease = try await reader.acquire()
        try checkActive(run)
        guard let lease = run.lease else { throw ScreenSaverFailure(code: .leaseFailure(.load)) }
        let manifest = lease.manifest
        let audio = ScreenSaverAudioPolicy(context: audioContext, isMuted: manifest.isMuted)
        let entries = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.id, $0) })
        let files = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.id, $0) })
        var cursor = PlaylistCursor()
        while true {
            try checkActive(run)
            let proposal = try cursor.prepare(ids: manifest.entries.map(\.id), mode: manifest.mode)
            guard let entry = entries[proposal.entryID], let file = files[entry.mediaID] else {
                throw ScreenSaverFailure(code: .invalidProjection)
            }
            try await run.renderer.show(item: ScreenSaverSnapshotReader.media(file, directory: lease.directory),
                entry: entry, fit: manifest.fit, audio: audio, transition: manifest.transition)
            try checkActive(run)
            guard cursor.commit(proposal) else {
                throw ScreenSaverFailure(code: .transactionConflict(.load))
            }
            // The dwell clock begins only after a real frame and its transition are committed.
            let clock = PlaybackClock(duration: entry.timing.duration(mediaDuration: file.duration), now: now)
            state.phase = .playing; state.generationID = manifest.generationID
            state.entryID = entry.id; state.audio = audio
            onStateChange?(state)
            try checkActive(run)
            if manifest.entries.count == 1 || manifest.mode == .repeatOne { return }
            try await Task.sleep(for: .seconds(clock.remaining(now: now)))
        }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func checkActive(_ run: Run) throws {
        try Task.checkCancellation()
        guard active === run else { throw CancellationError() }
    }

    private func fail(_ error: Error, run: Run) {
        run.failure = error
        if active === run { active = nil }
        if visibleRunID == run.id {
            state.phase = .failed
            state.failure = ScreenSaverFailure(capturing: error, phase: .load)
            onStateChange?(state)
        }
        report(error, run: run)
        _ = beginClose(run)
    }

    private func beginClose(_ run: Run) -> Task<Void, Error> {
        run.renderer.revoke()
        run.work?.cancel()
        if run.closing, let task = run.close { return task }
        run.closing = true
        let task = Task { [self] in
            await run.work?.value
            do {
                try await run.renderer.close()
                try await run.lease?.close()
                run.lease = nil
                try run.access?.close()
                run.access = nil
                runs.removeValue(forKey: run.id)
                run.closing = false
                if visibleRunID == run.id {
                    state.phase = run.failure == nil ? .stopped : .failed
                    state.failure = run.failure.map { ScreenSaverFailure(capturing: $0, phase: .load) }
                    onStateChange?(state)
                }
            } catch {
                let failure = WallpaperErrorGroup([run.failure, error].compactMap { $0 })
                // The failed attempt has finished; an error callback may explicitly retry it.
                run.closing = false
                if visibleRunID == run.id {
                    state.phase = .failed
                    state.failure = ScreenSaverFailure(capturing: failure, phase: .release)
                    onStateChange?(state)
                }
                report(failure, run: run)
                throw failure
            }
        }
        run.close = task
        // Register the barrier before notifying clients, which may synchronously call stop again.
        if visibleRunID == run.id, run.failure == nil {
            state.phase = .stopping; onStateChange?(state)
        }
        return task
    }

    private func report(_ error: Error, run: Run) {
        Self.logger.error("Session \(run.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        onError?(run.id, error)
    }
}
