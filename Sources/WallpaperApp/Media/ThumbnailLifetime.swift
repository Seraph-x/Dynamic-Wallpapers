import AppKit
import WallpaperCore

/// Grid tasks outlive their SwiftUI cards while decoders drain; deletion waits on this owner.
@MainActor
final class ThumbnailLifetime: ObservableObject {
    typealias Load = @MainActor (MediaItem) async throws -> NSImage?
    private struct Request {
        let mediaID: UUID
        let task: Task<NSImage?, Error>
    }
    private let loadImage: Load
    private var requests: [UUID: Request] = [:]
    private var removedIDs = Set<UUID>()
    private var stopped = false
    @Published private(set) var cachedImages: [UUID: NSImage] = [:]
    var onReleaseError: ((Error) -> Void)?

    init(load: @escaping Load = MediaThumbnail.load) { loadImage = load }

    func load(_ item: MediaItem) async throws -> NSImage? {
        try Task.checkCancellation()
        guard !stopped, !removedIDs.contains(item.id) else { throw CancellationError() }
        if let cached = cachedImages[item.id] { return cached }
        let id = UUID()
        let task = Task { try await loadImage(item) }
        requests[id] = Request(mediaID: item.id, task: task)
        do {
            let image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            requests.removeValue(forKey: id)
            try Task.checkCancellation()
            if let image { cachedImages[item.id] = image }
            return image
        } catch {
            if Self.isReleaseFailure(error) { onReleaseError?(error) }
            else { requests.removeValue(forKey: id) }
            throw error
        }
    }

    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        removedIDs.formUnion(ids)
        ids.forEach { cachedImages.removeValue(forKey: $0) }
        return drain(requests.values.filter { ids.contains($0.mediaID) })
    }

    func cachedImage(for id: UUID) -> NSImage? { cachedImages[id] }

    func beginShutdown() -> Task<Void, Error> {
        stopped = true
        return drain(Array(requests.values))
    }

    private func drain(_ requests: [Request]) -> Task<Void, Error> {
        requests.forEach { $0.task.cancel() }
        return Task {
            var failures: [Error] = []
            for request in requests {
                if case .failure(let error) = await request.task.result, Self.isReleaseFailure(error) { failures.append(error) }
            }
            // Ordinary decode failures were surfaced to the caller and do not retain a reader.
            if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
        }
    }

    private static func isReleaseFailure(_ error: Error) -> Bool {
        error is MediaProbeCleanupFailure || error is TranscodeReleaseError
    }
}
