import Combine
import Foundation
import WallpaperCore

/// Application-owned preparation and serial queue; closing a view cannot discard
/// a running process. A replaced probe also drains before its successor starts.
@MainActor
final class TranscodeModel: ObservableObject {
    typealias ToolsProvider = @MainActor () throws -> TranscodeTools
    typealias Inspect = @MainActor (URL) async throws -> TranscodeMedia

    @Published private(set) var source: MediaItem?
    @Published private(set) var media: TranscodeMedia?
    @Published private(set) var isProbing = false
    @Published private(set) var isShuttingDown = false
    @Published var preset: TranscodePreset = .original
    @Published var failure: PresentedFailure?
    var errorMessage: String? { failure?.localizedDescription }
    let queue: TranscodeQueue
    private let inspect: Inspect
    private var generation = UUID()
    private var probeTask: Task<Void, Error>?
    private var shutdownTask: Task<Void, Error>?
    private var probeSources: [UUID: URL] = [:]
    private var unreleasedFiles = Set<URL>()
    private var removedMediaIDs = Set<UUID>()

    init(queue: TranscodeQueue? = nil, tools: @escaping ToolsProvider = { try TranscodeTools.resolve() },
         inspect: Inspect? = nil) {
        self.inspect = inspect ?? { source in try await FFmpegJob.inspect(source: source, tools: tools()) }
        self.queue = queue ?? TranscodeQueue { request, progress in
            try await FFmpegJob.run(request: request, tools: tools(), onProgress: progress)
        }
    }

    var hasActiveWork: Bool { isProbing || queue.hasActiveJobs }
    var plan: Result<TranscodePlan, Error>? {
        guard let media else { return nil }
        return Result { try TranscodePlan(media: media, preset: preset) }
    }

    func select(_ item: MediaItem) {
        guard !removedMediaIDs.contains(item.id) else {
            failure = PresentedFailure(WallpaperError("壁纸已从素材库移除，无法开始转码。"), context: .transcode); return
        }
        guard !isShuttingDown else {
            failure = PresentedFailure(WallpaperError("应用正在退出，无法开始转码。"), context: .transcode); return
        }
        guard item.kind == .video else {
            failure = PresentedFailure(WallpaperError("仅视频壁纸支持转码。"), context: .transcode); return
        }
        source = item; media = nil; failure = nil; isProbing = true
        let previous = probeTask
        previous?.cancel()
        generation = UUID()
        let requestGeneration = generation
        probeSources[requestGeneration] = item.url
        probeTask = Task {
            var inspectionStarted = false
            defer {
                probeSources.removeValue(forKey: requestGeneration)
                if requestGeneration == generation { isProbing = false }
            }
            do {
                // Each task carries its own release result. A successor cannot
                // reset or erase an older failure while shutdown waits for it.
                try await previous?.value
                guard requestGeneration == generation else { return }
                try Task.checkCancellation()
                inspectionStarted = true
                let result = try await inspect(item.url)
                try Task.checkCancellation()
                if requestGeneration == generation, !isShuttingDown { media = result }
            } catch is CancellationError { }
            catch let error as TranscodeReleaseError {
                if inspectionStarted { unreleasedFiles.formUnion(error.retainedFileURLs) }
                if requestGeneration == generation { failure = PresentedFailure(error, context: .transcode) }
                throw error
            }
            catch {
                if requestGeneration == generation { failure = PresentedFailure(error, context: .transcode) }
            }
        }
    }

    func validateRemoval(_ items: [MediaItem]) throws {
        let inUse = Set((Array(probeSources.values) + Array(unreleasedFiles) + queue.inUseURLs)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL })
        for item in items {
            if TranscodeFileAccess.blocksRemoval(of: item, normalizedURLs: inUse) {
                throw WallpaperError("“\(item.name)”仍被转码任务使用，请等待任务结束或取消完成后再删除。")
            }
        }
    }

    func didRemoveMedia(_ ids: Set<UUID>) {
        removedMediaIDs.formUnion(ids)
        if let source, ids.contains(source.id) { self.source = nil; media = nil }
    }

    @discardableResult
    func enqueue(directory: URL, name: String, managedMediaDirectory: URL) -> Bool {
        do {
            guard !isShuttingDown, !queue.isShuttingDown else { throw WallpaperError("应用正在退出，无法开始转码。") }
            guard let source, let plan else { throw WallpaperError("请先选择视频并等待检查完成。") }
            guard directory.isFileURL, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !name.contains("/"), !name.contains("\0"),
                  URL(fileURLWithPath: name).pathExtension.lowercased() == "mp4" else {
                throw WallpaperError("请输入以 .mp4 结尾的文件名，不要包含文件夹路径。")
            }
            let root = managedMediaDirectory.standardizedFileURL
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard !directory.standardizedFileURL.pathComponents.starts(with: root.pathComponents),
                  !directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(with: resolvedRoot.pathComponents) else {
                throw WallpaperError("转码输出不能保存在应用托管素材目录中，请选择其他目录。", diagnostic: directory.path)
            }
            let request = try TranscodeRequest(source: source.url, destination: directory.appendingPathComponent(name),
                                              plan: plan.get())
            try FFmpegJob.requireAbsent(request.destination)
            guard !queue.jobs.contains(where: { $0.state.isActive && $0.request.destination.standardizedFileURL == request.destination.standardizedFileURL }) else {
                throw WallpaperError("已有任务使用这个输出路径，请更名。")
            }
            queue.enqueue(request)
            failure = nil
            return true
        } catch { failure = PresentedFailure(error, context: .transcode); return false }
    }

    func beginShutdown() -> Task<Void, Error> {
        if let shutdownTask { return shutdownTask }
        isShuttingDown = true
        probeTask?.cancel()
        let probe = probeTask
        let queueClosing = queue.beginShutdown()
        let task = Task<Void, Error> {
            var failures: [Error] = []
            do { try await probe?.value } catch { failures.append(error) }
            do { try await queueClosing.value } catch { failures.append(error) }
            if !failures.isEmpty { throw WallpaperErrorGroup(failures) }
        }
        shutdownTask = task
        return task
    }
}
