import AppKit
import WallpaperCore

/// Grid tasks outlive their SwiftUI cards while decoders drain; deletion waits on this owner.
@MainActor
final class ThumbnailLifetime {
    typealias Load = @MainActor (MediaItem) async throws -> NSImage?
    private struct Request {
        let mediaID: UUID
        let task: Task<NSImage?, Error>
    }
    private let loadImage: Load
    private var requests: [UUID: Request] = [:]
    private var removedIDs = Set<UUID>()
    private var stopped = false
    private let cachedImages = NSCache<NSUUID, NSImage>()
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
        if let cached = cachedImage(for: item.id) { return cached }
        let id = UUID()
        let task = Task { try await loadImage(item) }
        requests[id] = Request(mediaID: item.id, task: task)
        do {
            let image = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            requests.removeValue(forKey: id)
            try Task.checkCancellation()
            if let image, !stopped, !removedIDs.contains(item.id) {
                cachedImages.setObject(image, forKey: item.id as NSUUID, cost: Self.pixelCost(image))
            }
            return image
        } catch {
            if Self.isReleaseFailure(error) { onReleaseError?(error) }
            else { requests.removeValue(forKey: id) }
            throw error
        }
    }

    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        removedIDs.formUnion(ids)
        ids.forEach { cachedImages.removeObject(forKey: $0 as NSUUID) }
        return drain(requests.values.filter { ids.contains($0.mediaID) })
    }

    func cachedImage(for id: UUID) -> NSImage? { cachedImages.object(forKey: id as NSUUID) }

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
