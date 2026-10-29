import Combine
import Foundation
import WallpaperCore
import WallpaperMediaIntegration

/// Shares one native provider while each page owns its disclosure and command lifetime.
@MainActor
final class SceneMediaSessionOwner: ObservableObject {
    typealias Command = (Data, UInt64) async throws -> Void

    private final class Slot {
        var command: Command?
        var active = false
        var closing = false
        var revision: UInt64 = 1
        var identity: SystemMediaArtworkIdentity?
        var projection: SystemMediaSceneSnapshot?
        var publication: UInt64 = 0
        var tail: Task<Void, Never>?
        var controls: [UUID: Task<Void, Error>] = [:]
    }

    let controller: SystemMediaController
    @Published private(set) var failures: [UUID: Error] = [:]
    @Published private(set) var artworkFailures: [UUID: String] = [:]
    private var slots: [UUID: Slot] = [:]
    private var artworkObservation: AnyCancellable?
    private var shuttingDown = false
    private var shutdownTask: Task<Void, Never>?
    var count: Int { slots.count }

    init(controller: SystemMediaController) {
        self.controller = controller
        controller.onSnapshot = { [weak self] _ in self?.publish() }
        // @Published sends before assignment. Use the emitted artwork state;
        // metadata has already been assigned before its artwork update starts.
        artworkObservation = controller.artwork.$state.sink { [weak self] state in
            self?.publish(artwork: state)
        }
    }

    func register(_ id: UUID) {
        precondition(!shuttingDown && slots[id] == nil, "A scene media instance registers only once")
        slots[id] = Slot()
    }

    func prepare(_ id: UUID, command: @escaping Command) async throws {
        guard !shuttingDown, let slot = slots[id], !slot.closing, slot.command == nil else {
            throw CancellationError()
        }
        slot.command = command
        publish()
        try await settled(id)
        guard !slot.closing else { throw CancellationError() }
    }

    func setPlaying(_ id: UUID, _ value: Bool) {
        guard !shuttingDown, let slot = slots[id], !slot.closing, slot.command != nil,
              slot.active != value else { return }
        slot.active = value
        invalidate(slot) // Invalidate before a provider callback or queued action can run.
        artworkFailures.removeValue(forKey: id)
        controller.setPlaying(id, value)
        publish()
    }

    /// Wait through the latest queued frame, including clears queued during an await.
    func settled(_ id: UUID) async throws {
        guard let slot = slots[id] else { throw CancellationError() }
        while let pending = slot.tail {
            let publication = slot.publication
            await pending.value
            if publication == slot.publication { break }
        }
        if let failure = failures[id] { throw failure }
    }

    func perform(_ command: SystemMediaCommand, id: UUID, revision: UInt64) async throws {
        guard let slot = slots[id], isCurrent(id, slot: slot, revision: revision) else {
            throw CancellationError()
        }
        let token = UUID()
        let task = Task { @MainActor [self] in
            do {
                try await controller.perform(command, whileCurrent: { [weak self, weak slot] in
                    guard let self, let slot else { return false }
                    return self.isCurrent(id, slot: slot, revision: revision)
                })
            } catch {
                if !(error is CancellationError), isCurrent(id, slot: slot, revision: revision) {
                    failures[id] = error
                }
                throw error
            }
        }
        slot.controls[token] = task
        defer { slot.controls.removeValue(forKey: token) }
        try await task.value
    }

    func artworkFailed(_ id: UUID, revision: UInt64, message: String) {
        guard let slot = slots[id], isCurrent(id, slot: slot, revision: revision) else { return }
        artworkFailures[id] = message
    }

    func retryArtwork() async {
        guard !shuttingDown else { return }
        for (id, slot) in slots where slot.active && !slot.closing {
            invalidate(slot)
            slot.projection = nil
            artworkFailures.removeValue(forKey: id)
        }
        publish()
        await controller.artwork.retry()
    }

    func beginClose(_ id: UUID) {
        guard let slot = slots[id], !slot.closing else { return }
        slot.closing = true; slot.active = false; invalidate(slot)
        controller.setPlaying(id, false)
    }

    /// The page closes first, so a native frame wait can be cancelled by real CEF close.
    func retire(_ id: UUID) async {
        guard let slot = slots[id] else { return }
        beginClose(id)
        await drain(slot)
        slots.removeValue(forKey: id)
        failures.removeValue(forKey: id); artworkFailures.removeValue(forKey: id)
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        shuttingDown = true
        for id in Array(slots.keys) { beginClose(id) }
        let task = Task { @MainActor [self] in
            await controller.shutdown()
            for slot in Array(slots.values) { await drain(slot) }
            slots.removeAll(); failures.removeAll(); artworkFailures.removeAll()
        }
        shutdownTask = task
        await task.value
    }

    private func isCurrent(_ id: UUID, slot: Slot, revision: UInt64) -> Bool {
        guard !shuttingDown, slots[id] === slot, !slot.closing, slot.active,
              slot.revision == revision, let snapshot = controller.snapshot else { return false }
        return slot.identity == SystemMediaArtworkIdentity(snapshot)
    }

    private func publish(artwork: SystemMediaArtworkState? = nil) {
        guard !shuttingDown else { return }
        let artwork = artwork ?? controller.artwork.state
        for (id, slot) in slots where slot.command != nil && !slot.closing {
            let snapshot = slot.active ? controller.snapshot : nil
            let identity = snapshot.map(SystemMediaArtworkIdentity.init)
            if slot.identity != identity {
                slot.identity = identity; invalidate(slot)
                artworkFailures.removeValue(forKey: id)
            }
            let projection = SystemMediaSceneSnapshot(snapshot: snapshot, artwork: artwork)
            guard slot.projection != projection || failures[id] != nil else { continue }
            slot.projection = projection
            enqueue(projection, id: id, slot: slot)
        }
    }

    private func enqueue(_ projection: SystemMediaSceneSnapshot, id: UUID, slot: Slot) {
        guard let command = slot.command else { return }
        let previous = slot.tail, revision = slot.revision
        slot.publication += 1
        let publication = slot.publication
        slot.tail = Task { @MainActor [weak self, weak slot] in
            await previous?.value
            guard let self, let slot, !slot.closing, slot.revision == revision,
                  slot.publication == publication else { return }
            do {
                try await command(JSONEncoder().encode(projection), revision)
                guard !slot.closing, slot.publication == publication else { return }
                self.failures.removeValue(forKey: id)
            } catch {
                fputs("DWWEB MEDIA publication failed: \(error.localizedDescription)\n", stderr)
                guard !slot.closing, slot.revision == revision, slot.publication == publication else { return }
                self.failures[id] = error
            }
        }
    }

    private func drain(_ slot: Slot) async {
        await slot.tail?.value
        for task in Array(slot.controls.values) { _ = await task.result }
        // Publication errors are observable above; control callers own thrown errors.
    }

    private func invalidate(_ slot: Slot) {
        slot.revision += 1
        for task in slot.controls.values { task.cancel() }
    }
}
