import WallpaperAudioSpectrum
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

    init(owner: CEFApplicationRuntime, size: CGSize, frameRate: WebWallpaperFrameRate) {
        self.owner = owner; self.size = size; self.frameRate = frameRate
        view = NSView(frame: CGRect(origin: .zero, size: size))
    }

    func prepare(project: SceneProjectReference, scale: CGFloat, fit: ContentFit) async throws {
        guard !started, !closing else { throw WallpaperError("场景实例已使用或正在关闭。") }
        started = true
        try Task.checkCancellation()
        let page = try owner.createScenePage(project: project, id: id, size: size, scale: scale)
        self.page = page
        view = page.view
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
        if !value { owner.setScenePlaying(id, false) }
        try await command { page.setScenePlaying(value, completion: $0) }
        owner.setScenePlaying(id, value && playbackIntent)
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
        owner.setScenePlaying(id, false)
        finishPreparation(.failure(CancellationError()))
        page?.onReady = nil; page?.onError = nil
        let page = self.page
        var gateFailure: Error?
        do { try page?.setOutputGain(0) } catch { gateFailure = error }
        let task = Task { @MainActor [gateFailure] in
            if let page {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    page.close { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            self.page = nil
            self.owner.retireScene(self.id)
            if let gateFailure { throw gateFailure }
        }
        closeTask = task
        try await task.value
    }
}
