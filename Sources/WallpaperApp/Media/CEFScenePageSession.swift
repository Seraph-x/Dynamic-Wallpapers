import WallpaperAudioSpectrum
import WallpaperMediaIntegration
import AppKit
import WallpaperCore
import WebWallpaperBridge

@MainActor
final class CEFScenePageSession: ScenePageSession {
    let id = UUID()
    private(set) var view: NSView
    var onError: ((Error) -> Void)?
    private let owner: CEFApplicationRuntime
    private let size: CGSize
    private var frameRate: WebWallpaperFrameRate
    private var page: DWWebPage?
    private var preparation: CheckedContinuation<Void, Error>?
    private var started = false
    private var closing = false
    private var playbackIntent = false
    private var closeTask: Task<Void, Error>?
    private let readProperties: @Sendable (MediaItem) throws -> ScenePropertyCatalogCapture
    private var metadataTask: Task<ScenePropertyCatalogCapture, Error>?

    init(owner: CEFApplicationRuntime, size: CGSize, frameRate: WebWallpaperFrameRate,
         readProperties: @escaping @Sendable (MediaItem) throws -> ScenePropertyCatalogCapture = { try SceneProjectProbe.propertyCatalog($0) }) {
        self.owner = owner; self.size = size; self.frameRate = frameRate
        self.readProperties = readProperties
        view = NSView(frame: CGRect(origin: .zero, size: size))
    }

    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws {
        guard !started, !closing else { throw WallpaperError("场景实例已使用或正在关闭。") }
        guard let project = item.sceneProject, item.backend == .scene else { throw WallpaperError("场景工程无效。") }
        started = true
        owner.sceneProperties.register(id, item: item)
        owner.sceneMedia.register(id)
        try Task.checkCancellation()
        let readProperties = readProperties
        let capture = try await metadata { try readProperties(item) }
        guard !closing else { throw CancellationError() }
        try Task.checkCancellation()
        let page = try owner.createScenePage(project: project, id: id, size: size, scale: scale)
        self.page = page
        bindMediaCallbacks(page)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                preparation = continuation
                page.onReady = { [weak self] in self?.finishPreparation(.success(())) }
                page.onError = { [weak self] error in
                    guard let self, !self.closing else { return }
                    self.owner.setScenePlaying(self.id, false)
                    if self.preparation != nil { self.finishPreparation(.failure(error)) }
                    else { self.onError?(error) }
                }
                page.start()
            }
            try Task.checkCancellation()
            try await setPlaying(false)
            try await command { page.setSceneFit(fit == .fill ? "cover" : "contain", completion: $0) }
            try await command { page.setSceneFrameRate(UInt(frameRate.rawValue), completion: $0) }
            try await command { page.setSceneVolume(1, muted: false, completion: $0) }
            try setGain(0)
            _ = try await metadata { try SceneProjectProbe.revalidate(capture); return capture }
            try Task.checkCancellation()
            try await owner.sceneProperties.prepare(id, capture: capture) { [weak self, weak page] bytes in
                guard let self, let page else { throw CancellationError() }
                try await self.command { page.setSceneUserPropertiesJSONData(bytes, completion: $0) }
            }
            try await owner.sceneMedia.prepare(id) { [weak self, weak page] bytes, revision in
                guard let self, let page else { throw CancellationError() }
                try await self.command { page.setSceneMediaSnapshotJSONData(bytes, mediaRevision: revision, completion: $0) }
            }
            try await owner.sceneProperties.attach(id) { self.view = page.view }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishPreparation(.failure(CancellationError())) }
        }
    }

    func setGain(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else { throw WallpaperError("场景输出增益无效。") }
        guard let page else {
            guard value == 0 else { throw WallpaperError("场景尚未就绪，无法启用声音。") }
            return
        }
        try page.setOutputGain(value)
    }
    func setPlaying(_ value: Bool) async throws {
        guard !closing, let page else { throw CancellationError() }
        if !value {
            owner.setScenePlaying(id, false)
            try await owner.sceneMedia.settled(id)
        }
        try await command { page.setScenePlaying(value, completion: $0) }
        owner.setScenePlaying(id, value && playbackIntent)
        try await owner.sceneMedia.settled(id)
    }
    func setPlaybackIntent(_ value: Bool) {
        playbackIntent = value
        if !value { owner.setScenePlaying(id, false) }
    }
    func updateSpectrum(_ value: AudioSpectrum) {
        guard !closing, let page, page.ready else { return }
        do { try page.setSceneSpectrumLeft(value.left.map { NSNumber(value: $0) }, right: value.right.map { NSNumber(value: $0) }) }
        catch { owner.systemAudioSpectrum.setPlaying(id, false); onError?(error) }
    }
    func setFrameRate(_ value: WebWallpaperFrameRate) {
        frameRate = value
        guard !closing, let page, page.ready else { return }
        Task { @MainActor [weak self] in
            do { try await self?.command { page.setSceneFrameRate(UInt(value.rawValue), completion: $0) } }
            catch { if self?.closing == false { self?.onError?(error) } }
        }
    }
    func sendPointer(at point: CGPoint, kind: String) throws {
        guard !closing, let page, page.ready else { throw WallpaperError("场景当前不能接收鼠标输入。") }
        try page.sendScenePointer(at: point, kind: kind)
    }
    private func bindMediaCallbacks(_ page: DWWebPage) {
        page.onSceneMediaControl = { [weak self] event in
            guard let self, !self.closing else { return }
            guard let raw = event["command"] as? String, let command = SystemMediaCommand(rawValue: raw),
                  let revision = event["mediaRevision"] as? NSNumber else {
                self.onError?(WallpaperError("Invalid native media control event.")); return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await self.owner.sceneMedia.perform(command, id: self.id, revision: revision.uint64Value) }
                catch { fputs("DWWEB MEDIA control failed: \(error.localizedDescription)\n", stderr) }
            }
        }
        page.onSceneMediaArtworkError = { [weak self] event in
            guard let self, !self.closing else { return }
            guard let message = event["message"] as? String, let revision = event["mediaRevision"] as? NSNumber else {
                self.onError?(WallpaperError("Invalid native media artwork event.")); return
            }
            self.owner.sceneMedia.artworkFailed(self.id, revision: revision.uint64Value, message: message)
        }
    }
    private func metadata(_ read: @escaping @Sendable () throws -> ScenePropertyCatalogCapture) async throws -> ScenePropertyCatalogCapture {
        let task = Task.detached(operation: read)
        metadataTask = task
        defer { metadataTask = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func command(_ invoke: (@escaping (Error?) -> Void) -> Void) async throws {
        guard !closing else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            invoke { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        guard !closing else { throw CancellationError() }
    }
    private func finishPreparation(_ result: Result<Void, Error>) {
        guard let continuation = preparation else { return }
        preparation = nil
        continuation.resume(with: result)
    }
    func close() async throws {
        if let closeTask { try await closeTask.value; return }
        closing = true
        owner.sceneProperties.beginClose(id)
        owner.sceneMedia.beginClose(id)
        owner.setScenePlaying(id, false)
        finishPreparation(.failure(CancellationError()))
        page?.onReady = nil; page?.onError = nil
        page?.onSceneMediaControl = nil; page?.onSceneMediaArtworkError = nil
        let pendingMetadata = metadataTask
        pendingMetadata?.cancel()
        let page = self.page
        var gateFailure: Error?
        do { try page?.setOutputGain(0) } catch { gateFailure = error }
        let task = Task { @MainActor [gateFailure] in
            _ = await pendingMetadata?.result // The preparation caller owns read errors.
            if let page {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    page.close { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            try await self.owner.sceneProperties.retire(self.id)
            await self.owner.sceneMedia.retire(self.id)
            self.page = nil
            self.owner.retireScene(self.id)
            if let gateFailure { throw gateFailure }
        }
        closeTask = task
        try await task.value
    }
}
