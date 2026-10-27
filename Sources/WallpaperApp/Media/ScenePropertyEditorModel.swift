import Combine
import Foundation
import WallpaperCore

/// Saves library overrides before publishing acknowledged data-only commands.
@MainActor
final class ScenePropertyEditorModel: ObservableObject {
    @Published private(set) var catalog: ScenePropertyCatalog?
    @Published private(set) var values: [Data: ScenePropertyValue] = [:]
    @Published private(set) var failure: Error?
    @Published private(set) var status: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var hasInvalidStoredValues = false
    private let read: (MediaItem) async throws -> ScenePropertyCatalogCapture
    private let revalidate: (ScenePropertyCatalogCapture) async throws -> Void
    private let currentItem: (UUID) -> MediaItem?
    private let commit: (MediaItem, [ScenePropertyOverride]) throws -> MediaItem
    private let publish: (MediaItem, ScenePropertyCatalogCapture, [ScenePropertyOverride]) async throws -> Void
    private var selected: MediaItem?
    private var capture: ScenePropertyCatalogCapture?
    private var revision = 0
    private var closed = false
    private var loading: Task<Void, Error>?
    private var reads: [UUID: (mediaID: UUID, task: Task<Void, Error>)] = [:]
    var selectionRevision: Int { revision }

    init(read: @escaping (MediaItem) async throws -> ScenePropertyCatalogCapture = { item in
        try await SceneProjectProbe.background { try SceneProjectProbe.propertyCatalog(item) }
    }, revalidate: @escaping (ScenePropertyCatalogCapture) async throws -> Void = { capture in
        try await SceneProjectProbe.background { try SceneProjectProbe.revalidate(capture) }
    }, currentItem: @escaping (UUID) -> MediaItem?,
         commit: @escaping (MediaItem, [ScenePropertyOverride]) throws -> MediaItem,
         publish: @escaping (MediaItem, ScenePropertyCatalogCapture, [ScenePropertyOverride]) async throws -> Void) {
        self.read = read; self.revalidate = revalidate; self.currentItem = currentItem
        self.commit = commit; self.publish = publish
    }

    func select(_ item: MediaItem?) {
        revision += 1; loading?.cancel()
        selected = item; capture = nil; catalog = nil; values = [:]
        failure = nil; status = nil; hasInvalidStoredValues = false; isLoading = false
        guard !closed, let item, item.backend == .scene else { return }
        isLoading = true
        let request = revision, readID = UUID()
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { return }
            defer { reads.removeValue(forKey: readID) }
            do {
                try Task.checkCancellation()
                let capture = try await read(item)
                guard request == revision, !closed, !Task.isCancelled else { return }
                self.capture = capture; catalog = capture.catalog
                do {
                    values = Dictionary(uniqueKeysWithValues: try capture.catalog.resolvedValues(overrides: item.scenePropertyOverrides).map { ($0.identity, $0.value) })
                } catch { hasInvalidStoredValues = true; failure = error }
            } catch {
                if request == revision, !closed, !Task.isCancelled { failure = error }
            }
            if request == revision { isLoading = false }
        }
        loading = task
        reads[readID] = (item.id, task)
    }

    func waitForLoading() async {
        while !reads.isEmpty {
            let pending = Array(reads.values)
            for read in pending { _ = await read.task.result }
        }
    }
    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        let pending = reads.values.filter { ids.contains($0.mediaID) }
        if let selected, ids.contains(selected.id) { select(nil) }
        pending.forEach { $0.task.cancel() }
        return Task { for read in pending { _ = await read.task.result } }
    }
    func shutdown() {
        closed = true
        reads.values.forEach { $0.task.cancel() }
        select(nil)
    }
    func reload() {
        guard !closed, !isSaving, let selected else { return }
        select(currentItem(selected.id))
    }

    func beginEditing() {
        guard !closed, !isSaving else { return }
        failure = nil; status = nil
    }

    func setValue(_ value: ScenePropertyValue, for row: ScenePropertyDefinition) {
        guard !closed, !isSaving, let actual = catalog?.rows.first(where: { $0.identity == row.identity }),
              actual.readOnlyReason == nil else { return }
        values[row.identity] = value; beginEditing()
    }

    func save(expectedRevision: Int? = nil) async -> Bool {
        guard expectedRevision == nil || expectedRevision == revision else { return false }
        return await persist(reset: false)
    }
    func reset(expectedRevision: Int? = nil) async -> Bool {
        guard expectedRevision == nil || expectedRevision == revision else { return false }
        return await persist(reset: true)
    }

    private func persist(reset: Bool) async -> Bool {
        guard !closed, !isSaving, let selected, let capture else { return false }
        let request = revision
        isSaving = true
        defer { isSaving = false }
        var saved = false
        do {
            guard reset || !hasInvalidStoredValues else { throw WallpaperError("已保存的场景属性无效，请显式重置。") }
            let overrides = reset ? [] : capture.catalog.rows.compactMap { row -> ScenePropertyOverride? in
                guard row.readOnlyReason == nil, let value = values[row.identity], value != row.defaultValue else { return nil }
                return ScenePropertyOverride(name: row.name, value: value)
            }
            try capture.catalog.validate(overrides: overrides)
            let resolved = try capture.catalog.resolvedValues(overrides: overrides)
            try await check(capture, mediaID: selected.id)
            guard !closed, request == revision, let current = currentItem(selected.id),
                  current.sceneProject == selected.sceneProject,
                  current.scenePropertyOverrides == selected.scenePropertyOverrides else { throw CancellationError() }
            let committed = try commit(current, overrides)
            saved = true
            self.selected = committed
            values = Dictionary(uniqueKeysWithValues: resolved.map { ($0.identity, $0.value) })
            hasInvalidStoredValues = false
            try await publish(committed, capture, resolved)
            guard !closed, request == revision else { return false }
            failure = nil; status = "场景属性已保存并应用"
            return true
        } catch {
            if !closed, request == revision {
                failure = error
                status = saved ? "设置已保存，实时应用失败" : nil
            }
            return false
        }
    }

    private func check(_ capture: ScenePropertyCatalogCapture, mediaID: UUID) async throws {
        let id = UUID()
        let task = Task<Void, Error> { @MainActor [self] in
            defer { reads.removeValue(forKey: id) }
            try Task.checkCancellation()
            try await revalidate(capture)
        }
        reads[id] = (mediaID, task)
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
