import Combine
import Foundation

/// Artwork has its own failure and task lifetime; metadata and transport stay independent.
@MainActor
public final class SystemMediaArtworkController: ObservableObject {
    @Published public private(set) var state: SystemMediaArtworkState = .unavailable
    private let service: (any SystemMediaArtworkServicing)?
    private let loader: any SystemMediaArtworkLoading
    private var identity: SystemMediaArtworkIdentity?
    private var revision = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var shuttingDown = false
    private var shutdownFinished = false
    private var shutdownTask: Task<Void, Never>?

    public init(service: (any SystemMediaArtworkServicing)?, loader: any SystemMediaArtworkLoading = HTTPSArtworkLoader()) {
        self.service = service; self.loader = loader
    }

    deinit { for task in tasks.values { task.cancel() } }

    /// Passing nil immediately clears the old item, including on demand/source loss.
    public func update(_ snapshot: SystemMediaSnapshot?) {
        guard !shuttingDown else { return }
        let next = snapshot.map(SystemMediaArtworkIdentity.init)
        if identity == next {
            guard case .unavailable = state, next != nil else { return }
        } else {
            invalidate(); identity = next
        }
        guard let next, let service else { return }
        start(next, service: service)
    }

    /// Failed artwork remains visible until an explicit retry or a different item.
    public func retry() async {
        guard !shuttingDown, let identity, let service else { return }
        invalidate()
        start(identity, service: service)
        await settled()
    }

    public func settled() async {
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            for task in pending { await task.value }
        }
    }

    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        shuttingDown = true; identity = nil; invalidate()
        let task = Task { @MainActor [self] in
            await settled()
            shutdownFinished = true
        }
        shutdownTask = task
        await task.value
    }

    /// The metadata owner calls this only after its complete shutdown was vetoed.
    public func cancelShutdown() {
        guard shuttingDown, shutdownFinished else { return }
        shuttingDown = false; shutdownFinished = false; shutdownTask = nil
    }

    private func invalidate() {
        revision += 1
        for task in tasks.values { task.cancel() }
        state = .unavailable
    }

    private func start(_ identity: SystemMediaArtworkIdentity, service: any SystemMediaArtworkServicing) {
        state = .pending(identity)
        let request = revision, id = UUID(), loader = loader
        tasks[id] = Task { @MainActor [weak self] in
            let result: Result<SystemMediaArtwork?, Error>
            do {
                try Task.checkCancellation()
                let source = try await service.readArtwork(for: identity)
                try Task.checkCancellation()
                if case .unavailable = source { result = .success(nil) }
                else { result = .success(try await loader.load(source, for: identity)) }
            } catch { result = .failure(error) }
            guard let self else { return }
            defer { self.tasks.removeValue(forKey: id) }
            guard !Task.isCancelled, !self.shuttingDown,
                  request == self.revision, identity == self.identity else { return }
            switch result {
            case .success(nil): self.state = .unavailable
            case .success(let artwork?):
                guard artwork.identity == identity else {
                    self.state = .failed(identity, SystemMediaError.trackChangedDuringRead); return
                }
                self.state = .ready(artwork)
            case .failure(let error): self.state = .failed(identity, error)
            }
        }
    }
}
