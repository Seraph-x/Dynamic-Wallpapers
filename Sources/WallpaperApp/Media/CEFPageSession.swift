import AppKit
import WebWallpaperBridge
import WallpaperCore

@MainActor
final class CEFPageSession: WebPageSession {
    let id = UUID()
    private(set) var view: NSView
    var onError: ((Error) -> Void)?
    private let owner: CEFApplicationRuntime
    private let size: CGSize
    private(set) var frameRate: WebWallpaperFrameRate
    private var page: DWWebPage?
    private var preparation: CheckedContinuation<Void, Error>?
    private var started = false
    private var closing = false
    private var closeTask: Task<Void, Error>?

    init(owner: CEFApplicationRuntime, size: CGSize, frameRate: WebWallpaperFrameRate) {
        self.owner = owner; self.size = size; self.frameRate = frameRate
        view = NSView(frame: CGRect(origin: .zero, size: size))
    }

    func prepare(project: WebProjectReference, scale: CGFloat) async throws {
        guard !started, !closing else { throw WallpaperError("网页实例已使用或正在关闭。") }
        started = true
        try Task.checkCancellation()
        let page = try owner.createPage(project: project, size: size, scale: scale)
        self.page = page
        // The surface mounts this only after prepare succeeds. Keep the actual
        // paint view so fit and layout apply to the layer that owns CEF pixels.
        view = page.view
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                preparation = continuation
                page.onReady = { [weak self] in self?.finishPreparation(.success(())) }
                page.onError = { [weak self] error in
                    guard let self, !self.closing else { return }
                    if self.preparation != nil { self.finishPreparation(.failure(error)) }
                    else { self.onError?(error) }
                }
                page.start()
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishPreparation(.failure(CancellationError())) }
        }
    }

    func setGain(_ gain: Double) throws {
        guard gain.isFinite, (0...1).contains(gain) else { throw WallpaperError("网页输出增益无效。") }
        guard let page else {
            guard gain == 0 else { throw WallpaperError("网页尚未就绪，无法启用声音。") }
            return
        }
        try page.setOutputGain(gain)
    }

    func setFrameRate(_ value: WebWallpaperFrameRate) {
        frameRate = value
        do { try page?.setFrameRate(UInt(value.rawValue)) }
        catch { onError?(error) }
    }

    func close() async throws {
        if let closeTask { try await closeTask.value; return }
        closing = true
        finishPreparation(.failure(CancellationError()))
        page?.onReady = nil; page?.onError = nil
        let page = self.page
        let task = Task { @MainActor in
            if let page {
                try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
                    page.close { error in
                        if let error { completion.resume(throwing: error) }
                        else { completion.resume() }
                    }
                }
            }
            self.page = nil
            self.owner.retire(self.id)
        }
        closeTask = task
        try await task.value
    }

    func sendClick(at point: CGPoint, clickCount: Int) throws {
        guard !closing, let page, page.ready else { throw WallpaperError("网页当前不能接收点击。") }
        try page.sendClick(at: point, clickCount: clickCount)
    }

    private func finishPreparation(_ result: Result<Void, Error>) {
        guard let continuation = preparation else { return }
        preparation = nil
        continuation.resume(with: result)
    }
}
