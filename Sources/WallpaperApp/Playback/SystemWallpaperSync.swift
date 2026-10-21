import AppKit
import Combine
import WallpaperCore

enum SystemWallpaperSyncState: Equatable {
    case waiting, syncing, synced(URL), failed(PresentedFailure)
}

@MainActor
final class SystemWallpaperSync: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var states: [String: SystemWallpaperSyncState] = [:]
    private let store: SystemWallpaperStore
    private let capture: (SystemWallpaperTarget) async throws -> CGImage
    private let isCurrent: (SystemWallpaperTarget) -> Bool
    private let apply: (URL, String) throws -> Void
    private var targets: [String: SystemWallpaperTarget] = [:]
    private var requests: [String: UUID] = [:]
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var shuttingDown = false

    init(store: SystemWallpaperStore,
         capture: @escaping (SystemWallpaperTarget) async throws -> CGImage,
         isCurrent: @escaping (SystemWallpaperTarget) -> Bool,
         apply: @escaping (URL, String) throws -> Void) {
        self.store = store; self.capture = capture; self.isCurrent = isCurrent; self.apply = apply
    }

    func setEnabled(_ value: Bool) {
        guard !shuttingDown, value != enabled else { return }
        enabled = value
        if value { targets.values.forEach(start) }
        else {
            for displayID in Array(requests.keys) { cancel(displayID) }
            states = targets.mapValues { _ in .waiting }
        }
    }

    func updateTargets(_ values: [SystemWallpaperTarget]) {
        guard !shuttingDown else { return }
        let incoming = Dictionary(uniqueKeysWithValues: values.map { ($0.displayID, $0) })
        let changed = incoming.values.filter { targets[$0.displayID] != $0 }
        for displayID in targets.keys where incoming[displayID] == nil {
            cancel(displayID); states.removeValue(forKey: displayID)
        }
        targets = incoming
        for target in changed {
            if enabled { start(target) }
            else { states[target.displayID] = .waiting }
        }
    }

    func retry(displayID: String) {
        guard enabled, !shuttingDown, let target = targets[displayID] else { return }
        start(target)
    }

    func shutdown() {
        guard !shuttingDown else { return }
        setEnabled(false)
        shuttingDown = true
    }

    func waitForPendingOperations() async {
        // Superseded captures may not support cancellation; retain and join them as well as the latest task.
        while !operations.isEmpty {
            let pending = Array(operations.values)
            for operation in pending { await operation.value }
        }
    }

    private func cancel(_ displayID: String) {
        if let id = requests.removeValue(forKey: displayID) { operations[id]?.cancel() }
    }

    private func start(_ target: SystemWallpaperTarget) {
        cancel(target.displayID)
        let id = UUID()
        requests[target.displayID] = id
        states[target.displayID] = .syncing
        operations[id] = Task { @MainActor in
            defer {
                self.operations.removeValue(forKey: id)
                if self.requests[target.displayID] == id { self.requests.removeValue(forKey: target.displayID) }
            }
            do {
                try self.check(id, target)
                let loadedVersion = try target.sourceVersion.get()
                let key = try await self.store.key(for: target.content)
                try self.check(id, target)
                guard key.sourceVersion == loadedVersion else { throw SystemWallpaperSourceVersionReader.changedSource }
                let cached = try await self.store.cachedImage(for: key)
                try self.check(id, target)
                let url: URL
                if let cached { url = cached }
                else {
                    let image = try await self.capture(target)
                    try self.check(id, target)
                    url = try await self.store.save(image, for: key)
                }
                try self.check(id, target)
                try await self.store.validateSource(for: key)
                try self.check(id, target)
                try self.apply(url, target.displayID)
                self.states[target.displayID] = .synced(url)
            } catch is CancellationError {
                if self.owns(id, target) { self.states[target.displayID] = .waiting }
            } catch {
                if self.owns(id, target) {
                    self.states[target.displayID] = .failed(PresentedFailure(error, context: .systemWallpaper))
                }
            }
        }
    }

    private func owns(_ id: UUID, _ target: SystemWallpaperTarget) -> Bool {
        enabled && !shuttingDown && requests[target.displayID] == id && targets[target.displayID] == target
    }

    private func check(_ id: UUID, _ target: SystemWallpaperTarget) throws {
        try Task.checkCancellation()
        guard owns(id, target), isCurrent(target) else { throw CancellationError() }
    }
}
