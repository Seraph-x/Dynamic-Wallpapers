import Combine
import Foundation
import WallpaperCore

public enum SystemMediaStatus: Sendable, Equatable {
    case disabled, waitingForPlayback, checking, applicationNotRunning
    case authorizationRequired, authorizationDenied, noCurrentItem, available, failed
}

/// Shared by actual playing scenes. Selecting a source never requests consent.
/// The owner supplies localized UI and connects onSnapshot to the renderer.
@MainActor
public final class SystemMediaController: ObservableObject {
    @Published public private(set) var source = SystemMediaSource.disabled
    @Published public private(set) var status = SystemMediaStatus.disabled
    @Published public private(set) var snapshot: SystemMediaSnapshot?
    @Published public private(set) var failure: Error?
    public let artwork: SystemMediaArtworkController
    public var onSnapshot: ((SystemMediaSnapshot?) -> Void)?

    private let service: any SystemMediaServicing
    private let pollInterval: TimeInterval
    private var subscribers = Set<UUID>()
    private var revision = 0
    private var operation: Task<Void, Never>?
    private var controls: [UUID: Task<Void, Error>] = [:]
    private var pendingReads = Set<Int>()
    private var authorizing = false
    private var blocked = false
    private var shuttingDown = false
    private var shutdownFinished = false
    private var shutdownTask: Task<Void, Never>?
    private var timer: Timer?

    public init(service: any SystemMediaServicing = AppleEventMediaService(), pollInterval: TimeInterval = 1,
                artworkLoader: any SystemMediaArtworkLoading = HTTPSArtworkLoader()) {
        precondition(pollInterval.isFinite && pollInterval > 0)
        self.service = service; self.pollInterval = pollInterval
        artwork = SystemMediaArtworkController(service: service as? any SystemMediaArtworkServicing, loader: artworkLoader)
    }

    deinit { timer?.invalidate() }

    public func configure(source: SystemMediaSource) {
        guard !shuttingDown, self.source != source else { return }
        self.source = source; revision += 1; cancelControls(); failure = nil; blocked = false
        stopTimer(); publish(nil)
        reconcile()
    }

    public func setPlaying(_ id: UUID, _ value: Bool) {
        guard !shuttingDown else { return }
        let wasActive = wantsReads
        if value { subscribers.insert(id) } else { subscribers.remove(id) }
        guard wasActive != wantsReads else { return }
        revision += 1
        cancelControls()
        if !wantsReads { stopTimer(); publish(nil) }
        reconcile()
    }

    /// An explicit user action. It may show the system Automation consent prompt.
    /// Repeated clicks while a prompt is pending do not queue more prompts.
    public func authorize() async {
        guard !shuttingDown, source != .disabled, !authorizing else { return }
        authorizing = true; blocked = false; failure = nil
        let request = revision, selected = source
        status = .checking
        append { [self] in
            defer { authorizing = false }
            guard request == revision, !shuttingDown else { return }
            await read(selected: selected, request: request, requestAuthorization: true)
        }
        await settled()
    }

    public func retry() async {
        guard !shuttingDown else { return }
        blocked = false; failure = nil
        reconcile()
        await settled()
    }

    /// Refresh never prompts and does not implicitly retry a blocked provider.
    public func refresh() async {
        scheduleRead()
        await settled()
    }

    public func settled() async { await operation?.value }

    /// Recheck the owning scene at actual OS dispatch, after any queued reads.
    /// A shared provider can remain active after this particular scene retires.
    public func perform(_ command: SystemMediaCommand,
                        whileCurrent: @escaping @MainActor () -> Bool = { true }) async throws {
        try Task.checkCancellation()
        guard whileCurrent() else { throw CancellationError() }
        guard !shuttingDown, source != .disabled else { throw SystemMediaError.disabled }
        guard wantsReads, !blocked, snapshot != nil else { throw SystemMediaError.noCurrentItem }
        let request = revision, selected = source, previous = operation, token = UUID()
        let task = Task { @MainActor [self] in
            await previous?.value
            try Task.checkCancellation()
            guard request == revision, wantsReads, whileCurrent() else { throw CancellationError() }
            guard !blocked, snapshot != nil else { throw SystemMediaError.noCurrentItem }
            do {
                try await service.perform(command, source: selected)
                try Task.checkCancellation()
                guard request == revision, wantsReads, whileCurrent() else { throw CancellationError() }
                let result = try await service.read(source: selected, requestAuthorization: false)
                try Task.checkCancellation()
                guard request == revision, wantsReads, whileCurrent() else { throw CancellationError() }
                apply(result)
            } catch {
                if request == revision, !shuttingDown, !(error is CancellationError) { fail(error) }
                throw error
            }
        }
        controls[token] = task
        // Preserve shared operation ordering without losing the individual task's
        // cancellation handler at the Task/GCD native-work boundary.
        operation = Task { _ = await task.result }
        defer { controls.removeValue(forKey: token) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Stops new work and drains dispatched OS operations. An already dispatched
    /// Apple Event or system consent dialog cannot be recalled by this controller.
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        shuttingDown = true; revision += 1; subscribers.removeAll()
        cancelControls()
        stopTimer(); publish(nil); status = .disabled
        let pending = operation
        let task = Task { @MainActor [self] in
            await pending?.value
            await artwork.shutdown()
            operation = nil; shutdownFinished = true
        }
        shutdownTask = task
        await task.value
    }

    /// Called only after shutdown completed when another quit participant vetoed.
    /// Existing scene demand is deliberately not resurrected by old callbacks.
    public func cancelShutdown() {
        guard shuttingDown, shutdownFinished else { return }
        shuttingDown = false; shutdownFinished = false; shutdownTask = nil
        artwork.cancelShutdown()
        reconcile()
    }

    private var wantsReads: Bool { source != .disabled && !subscribers.isEmpty && !shuttingDown }

    private func reconcile() {
        guard source != .disabled, !shuttingDown else { status = .disabled; return }
        guard !blocked else { return }
        guard wantsReads else { status = .waitingForPlayback; return }
        scheduleRead()
    }

    private func scheduleRead() {
        guard wantsReads, !blocked, pendingReads.insert(revision).inserted else { return }
        let request = revision, selected = source
        if snapshot == nil { status = .checking }
        append { [self] in
            defer { pendingReads.remove(request) }
            guard request == revision, wantsReads, !blocked else { return }
            await read(selected: selected, request: request, requestAuthorization: false)
        }
    }

    private func read(selected: SystemMediaSource, request: Int, requestAuthorization: Bool) async {
        do {
            let result = try await service.read(source: selected, requestAuthorization: requestAuthorization)
            guard request == revision, !shuttingDown else { return }
            apply(result)
        } catch {
            guard request == revision, !shuttingDown else { return }
            fail(error)
        }
    }

    private func apply(_ result: SystemMediaReadResult) {
        failure = nil
        switch result {
        case .authorizationRequired: blocked = true; status = .authorizationRequired; publish(nil)
        case .authorizationDenied: blocked = true; status = .authorizationDenied; publish(nil)
        case .applicationNotRunning: status = .applicationNotRunning; publish(nil)
        case .noCurrentItem: status = .noCurrentItem; publish(nil)
        case .current(let value):
            guard value.source == source else { fail(SystemMediaError.invalidResponse("Snapshot source does not match selection")); return }
            status = wantsReads ? .available : .waitingForPlayback
            publish(wantsReads ? value : nil)
        }
        if wantsReads, !blocked { startTimer() } else { stopTimer() }
    }

    private func fail(_ error: Error) {
        failure = error; blocked = true; status = .failed
        stopTimer(); publish(nil)
    }

    private func publish(_ value: SystemMediaSnapshot?) {
        snapshot = value; artwork.update(value); onSnapshot?(value)
    }

    private func append(_ work: @escaping @MainActor () async -> Void) {
        let previous = operation
        operation = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func cancelControls() { for task in controls.values { task.cancel() } }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRead() }
        }
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }
}
