import AppKit
import Combine
import WallpaperCore

/// The app owns inspection through replacement and shutdown, not the detail view.
@MainActor
final class InspectorMediaModel: ObservableObject {
    typealias Inspect = @MainActor (MediaItem) async throws -> MediaInspection

    @Published private(set) var source: MediaItem?
    @Published private(set) var image: NSImage?
    @Published private(set) var transcodeReason: String?
    @Published private(set) var failure: PresentedFailure?
    var errorMessage: String? { failure?.localizedDescription }
    @Published private(set) var isChecking = false
    @Published private(set) var isShuttingDown = false
    var onReleaseError: ((Error) -> Void)?
    private let inspect: Inspect
    private var generation = UUID()
    private var task: Task<Void, Error>?
    private var shutdownTask: Task<Void, Error>?
    private var removedMediaIDs = Set<UUID>()
    private struct InspectionRequest {
        let mediaID: UUID
        let task: Task<Void, Error>
        var isReading = false
    }
    private var requests: [UUID: InspectionRequest] = [:]
    private var releaseFailures: [UUID: Error] = [:]

    init(inspect: @escaping Inspect = { try await MediaCompatibility.inspect($0) }) {
        self.inspect = inspect
    }

    func select(_ item: MediaItem?) {
        if let item, removedMediaIDs.contains(item.id) { return }
        guard !isShuttingDown else {
            failure = PresentedFailure(WallpaperError("应用正在退出，无法检查壁纸。"), context: .inspection); return
        }
        source = item; image = nil; transcodeReason = nil; failure = nil
        isChecking = item != nil
        let previous = task
        previous?.cancel()
        generation = UUID()
        let request = generation
        let checking = Task<Void, Error> {
            defer {
                requests.removeValue(forKey: request)
                if generation == request { isChecking = false }
            }
            do {
                // Even an empty selection must preserve the preceding release result.
                try await previous?.value
                try Task.checkCancellation()
                guard let item else { return }
                requests[request]?.isReading = true
                let result = try await inspect(item)
                try Task.checkCancellation()
                guard generation == request, !isShuttingDown else { return }
                image = result.image
                transcodeReason = result.transcodeReason
            } catch is CancellationError { }
            catch {
                if generation == request { failure = PresentedFailure(error, context: .inspection) }
                if error is TranscodeReleaseError || error is MediaProbeCleanupFailure {
                    let paths = Set(TranscodeFileAccess.retainedURLs(in: error).map { $0.resolvingSymlinksInPath().standardizedFileURL })
                    if requests[request]?.isReading == true, let item,
                       error is MediaProbeCleanupFailure || TranscodeFileAccess.blocksRemoval(of: item, normalizedURLs: paths) {
                        releaseFailures[item.id] = error
                    }
                    onReleaseError?(error)
                    throw error
                }
            }
        }
        task = checking
        if let item { requests[request] = InspectionRequest(mediaID: item.id, task: checking) }
    }

    func retry() { if let source { select(source) } }

    func beginRemovingMedia(_ ids: Set<UUID>) -> Task<Void, Error> {
        removedMediaIDs.formUnion(ids)
        let matching = requests.values.filter { ids.contains($0.mediaID) }
        matching.forEach { $0.task.cancel() }
        if let source, ids.contains(source.id) { select(nil) }
        return Task {
            // Queued requests have not opened files. Inherited task errors belong
            // to their actual reader, not to the latest selection being removed.
            for request in matching where request.isReading { _ = await request.task.result }
            let failures = ids.compactMap { releaseFailures[$0] }
            if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
        }
    }

    func beginShutdown() -> Task<Void, Error> {
        if let shutdownTask { return shutdownTask }
        isShuttingDown = true
        task?.cancel()
        let inspecting = task
        let result = Task<Void, Error> { if let inspecting { try await inspecting.value } }
        shutdownTask = result
        return result
    }
}
