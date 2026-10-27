import Foundation
import WallpaperCore

/// One ordered property stream covers desktop, inspector and preview instances.
@MainActor
final class ScenePropertySessionOwner {
    private final class Slot {
        let item: MediaItem
        var capture: ScenePropertyCatalogCapture?
        var command: ((Data) async throws -> Void)?
        var failure: Error?
        var closing = false
        init(_ item: MediaItem) { self.item = item }
    }
    private struct Latest {
        let project: SceneProjectReference?
        let capture: ScenePropertyCatalogCapture?
        let values: [ScenePropertyOverride]
    }
    private var slots: [UUID: Slot] = [:]
    private var latest: [UUID: Latest] = [:]
    private var tail: Task<Void, Error>?
    var count: Int { slots.count }

    func register(_ id: UUID, item: MediaItem) {
        precondition(slots[id] == nil, "A scene instance can register only once")
        slots[id] = Slot(item)
        if latest[item.id] == nil {
            latest[item.id] = Latest(project: item.sceneProject, capture: nil, values: item.scenePropertyOverrides)
        }
    }

    func prepare(_ id: UUID, capture: ScenePropertyCatalogCapture,
                 command: @escaping (Data) async throws -> Void) async throws {
        guard let slot = slots[id], !slot.closing else { throw CancellationError() }
        try await enqueue { [self] in
            guard !slot.closing else { throw CancellationError() }
            guard slot.item.sceneProject == capture.project, let value = latest[slot.item.id],
                  value.project == capture.project else { throw WallpaperError("场景属性实例与工程不匹配。") }
            if let previous = value.capture { try validate(previous, matches: capture) }
            let resolved = try capture.catalog.resolvedValues(overrides: value.values)
            slot.capture = capture; slot.command = command
            do {
                try await command(capture.catalog.wireJSON(overrides: resolved))
                slot.failure = nil
            } catch { slot.failure = error; throw error }
            guard !slot.closing else { throw CancellationError() }
        }
    }

    func publish(item: MediaItem, capture: ScenePropertyCatalogCapture,
                 values: [ScenePropertyOverride]) async throws {
        guard item.sceneProject == capture.project else { throw WallpaperError("场景属性与工程不匹配。") }
        try capture.catalog.validate(overrides: values)
        try await enqueue { [self] in
            let receiving = slots.values.filter { $0.item.id == item.id && !$0.closing }
            for slot in receiving {
                guard slot.item.sceneProject == capture.project else { throw WallpaperError("场景实例的工程已变化。") }
                if let previous = slot.capture { try validate(previous, matches: capture) }
            }
            latest[item.id] = Latest(project: capture.project, capture: capture, values: values)
            let wire = try capture.catalog.wireJSON(overrides: values)
            var errors: [Error] = []
            for slot in receiving where !slot.closing {
                guard let command = slot.command else { continue } // Preparing instances consume latest before attachment.
                do { try await command(wire); slot.failure = nil }
                catch { slot.failure = error; errors.append(error) }
            }
            if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
            if receiving.isEmpty { latest.removeValue(forKey: item.id) }
        }
    }

    func attach(_ id: UUID, _ attach: @escaping () -> Void) async throws {
        guard let slot = slots[id], !slot.closing else { throw CancellationError() }
        try await enqueue {
            guard !slot.closing, slot.command != nil else { throw CancellationError() }
            if let failure = slot.failure { throw failure }
            attach()
        }
    }

    func beginClose(_ id: UUID) { slots[id]?.closing = true }

    func retire(_ id: UUID) async throws {
        guard let slot = slots[id] else { return }
        slot.closing = true
        let pending = tail
        _ = await pending?.result // Each command's original caller owns its error.
        slots.removeValue(forKey: id)
        if !slots.values.contains(where: { $0.item.id == slot.item.id }) {
            latest.removeValue(forKey: slot.item.id)
        }
    }

    private func validate(_ previous: ScenePropertyCatalogCapture, matches current: ScenePropertyCatalogCapture) throws {
        guard previous.project == current.project, previous.device == current.device,
              previous.inode == current.inode, previous.catalog.projectJSON == current.catalog.projectJSON else {
            throw WallpaperError("运行中的场景属性元数据已变化，请重新载入壁纸。")
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let task = Task { @MainActor in
            _ = await previous?.result
            try await operation()
        }
        tail = task
        try await task.value
    }
}
