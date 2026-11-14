import AppKit
import WallpaperCore

/// Grid tasks outlive their SwiftUI cards while decoders drain; deletion waits on this owner.
@MainActor
final class ThumbnailLifetime {
    typealias Load = @MainActor (MediaItem) async throws -> NSImage?
    private final class Request {
        let source: MediaItem
        let task: Task<NSImage?, Error>
        var subscribers = Set<UUID>()
        init(source: MediaItem, task: Task<NSImage?, Error>) {
            self.source = source; self.task = task
        }
    }
    private final class CachedImage {
        let source: MediaItem
        let image: NSImage
        init(source: MediaItem, image: NSImage) { self.source = source; self.image = image }
    }
    private let loadImage: Load
    private var requests: [UUID: Request] = [:]
    private var currentRequests: [UUID: UUID] = [:]
    private var removedIDs = Set<UUID>()
    private var stopped = false
    private let cachedImages = NSCache<NSUUID, CachedImage>()
    var onReleaseError: ((Error) -> Void)?

    init(load: @escaping Load = MediaThumbnail.load) {
        loadImage = load
        // Decoded pixels, not compressed file size. NSCache may also reclaim these
        // recomputable images under memory pressure; visible cards own their image.
        cachedImages.totalCostLimit = 32 * 1024 * 1024
        cachedImages.name = "Wallpaper thumbnails"
    }

    func load(_ item: MediaItem) async throws -> NSImage? {
        try Task.checkCancellation()
        guard !stopped, !removedIDs.contains(item.id) else { throw CancellationError() }
        let source = Self.source(item)
        if let cached = cachedImages.object(forKey: item.id as NSUUID), cached.source == source { return cached.image }
        let id: UUID
        if let current = currentRequests[item.id], let request = requests[current],
           request.source == source, !request.task.isCancelled {
            id = current
        } else {
            id = start(item, source: source)
        }
        guard let request = requests[id] else { preconditionFailure("Missing thumbnail request") }
        let subscriber = UUID()
        request.subscribers.insert(subscriber)
        defer { detach(subscriber, from: id) }
        let image = try await withTaskCancellationHandler {
            try await request.task.value
        } onCancel: { [weak self] in
            Task { @MainActor in self?.detach(subscriber, from: id) }
        }
        try Task.checkCancellation()
        guard !stopped, !removedIDs.contains(item.id) else { throw CancellationError() }
        return image
    }

    private func start(_ item: MediaItem, source: MediaItem) -> UUID {
        let id = UUID()
        let task = Task { () throws -> NSImage? in
            do {
                let image = try await loadImage(item)
                let current = currentRequests[item.id] == id
                if current { currentRequests.removeValue(forKey: item.id) }
                requests.removeValue(forKey: id)
                if let image, current, !Task.isCancelled, !stopped, !removedIDs.contains(item.id) {
                    cachedImages.setObject(CachedImage(source: source, image: image),
                        forKey: item.id as NSUUID, cost: Self.pixelCost(image))
                }
                return image
            } catch {
                if currentRequests[item.id] == id { currentRequests.removeValue(forKey: item.id) }
                if Self.isReleaseFailure(error) { onReleaseError?(error) }
                else { requests.removeValue(forKey: id) }
                throw error
            }
        }
        requests[id] = Request(source: source, task: task)
        currentRequests[item.id] = id
        return id
    }

    private func detach(_ subscriber: UUID, from id: UUID) {
        guard let request = requests[id] else { return }
        request.subscribers.remove(subscriber)
        guard request.subscribers.isEmpty else { return }
        if currentRequests[request.source.id] == id { currentRequests.removeValue(forKey: request.source.id) }
        request.task.cancel()
    }

    private static func source(_ item: MediaItem) -> MediaItem {
        var source = item
        source.customName = nil; source.isFavorite = false
        return source
    }

    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        removedIDs.formUnion(ids)
        ids.forEach { cachedImages.removeObject(forKey: $0 as NSUUID) }
        return drain(requests.values.filter { ids.contains($0.source.id) })
    }

    func cachedImage(for id: UUID) -> NSImage? { cachedImages.object(forKey: id as NSUUID)?.image }

    func beginShutdown() -> Task<Void, Error> {
        stopped = true
        cachedImages.removeAllObjects()
        return drain(Array(requests.values))
    }

    private static func pixelCost(_ image: NSImage) -> Int {
        image.representations.reduce(0) { total, representation in
            if let bitmap = representation as? NSBitmapImageRep {
                return total + bitmap.bytesPerRow * bitmap.pixelsHigh
            }
            return total + representation.pixelsWide * representation.pixelsHigh * 4
        }
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
