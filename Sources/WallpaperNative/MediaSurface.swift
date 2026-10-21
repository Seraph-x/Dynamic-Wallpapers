import AppKit
import AVFoundation
import WallpaperCore

@MainActor
public final class MediaSurface: NSView, PlaybackSurface {
    public var view: NSView { self }
    public private(set) var state: PlaybackSurfaceState = .idle
    private var generation = UUID()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoLayer: AVPlayerLayer?
    private var decoder: ImageDecoder?
    private var animationTasks: [UUID: Task<Void, Never>] = [:]
    private var preparationActive = false
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var asynchronousClose = false
    private var failureObserver: NSObjectProtocol?
    private var frameIndex = 0
    private var frameCount = 1
    private var frameRemaining: Double = 0
    private var frameDeadline: Double?
    private var audio = AudioSettings()
    private var globallyMuted = true
    private var audioSuppressed = false
    private var transitionGain = 1.0
    public var onError: ((Error) -> Void)?
    private(set) var isPlaying = false

    public init(size: CGSize, fit: ContentFit) {
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.contentsGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
        autoresizingMask = [.width, .height]
    }
    public required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }

    public func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws {
        try await prepare(item: item, scale: scale, fit: fit, timeout: 15)
    }

    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit, timeout: Double) async throws {
        guard state == .idle else { throw WallpaperError("播放器已准备或关闭，无法重新初始化。") }
        state = .preparing
        preparationActive = true
        defer {
            preparationActive = false
            let waiters = preparationWaiters
            preparationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let generation = self.generation
        do {
            try await prepareContents(item: item, scale: scale, fit: fit, timeout: timeout, generation: generation)
            try checkPreparation(generation)
            state = .ready
        } catch {
            dispose()
            throw error
        }
    }

    private func checkPreparation(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard self.generation == generation, state == .preparing else { throw CancellationError() }
    }

    private func prepareContents(item: MediaItem, scale: CGFloat, fit: ContentFit, timeout: Double, generation: UUID) async throws {
        guard item.backend == .native, item.kind != .web else {
            throw WallpaperError("该素材需要 \(item.backend.rawValue) 后端，不能交给原生播放器。")
        }
        guard FileManager.default.isReadableFile(atPath: item.url.path) else {
            throw WallpaperError("无法读取“\(item.url.lastPathComponent)”，请检查文件位置、读取权限和磁盘连接。")
        }
        if item.kind == .video { try await prepareVideo(url: item.url, fit: fit, timeout: timeout); return }
        let decoder = try ImageDecoder(url: item.url, maxPixelSize: Int(max(bounds.width, bounds.height) * scale))
        self.decoder = decoder
        let image = try await decoder.frame(at: 0)
        let delay = item.kind == .animatedImage ? try await decoder.delay(at: 0) : 0
        try checkPreparation(generation)
        layer?.contents = image
        frameCount = decoder.count
        frameRemaining = delay
    }

    private func prepareVideo(url: URL, fit: ContentFit, timeout: Double) async throws {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        let looper = AVPlayerLooper(player: player, templateItem: item)
        let videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
        videoLayer.frame = bounds
        layer?.addSublayer(videoLayer)
        self.player = player; self.looper = looper; self.videoLayer = videoLayer
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil, queue: .main) { [weak self] notification in
                guard let failed = notification.object as? AVPlayerItem else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.player?.currentItem === failed else { return }
                    self.pause()
                    self.onError?(failed.error ?? WallpaperError("视频播放失败。"))
                }
            }
        player.play()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !videoLayer.isReadyForDisplay {
            try Task.checkCancellation()
            guard state == .preparing else { throw CancellationError() }
            if looper.status == .failed { throw looper.error ?? WallpaperError("视频循环器准备失败。") }
            if player.currentItem?.status == .failed {
                throw player.currentItem?.error ?? WallpaperError("视频首帧解码失败。")
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw WallpaperError("视频加载超时（\(Int(timeout)) 秒）：\(url.lastPathComponent)。")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        player.pause()
    }

    public func play() {
        guard state == .ready || state == .paused else { return }
        state = .playing
        isPlaying = true
        applyAudio()
        player?.play()
        guard frameCount > 1, let decoder else { return }
        let animationID = UUID()
        animationTasks[animationID] = Task { [weak self] in
            guard let self else { return }
            defer { self.animationTasks.removeValue(forKey: animationID) }
            do {
                while !Task.isCancelled {
                    self.frameDeadline = ProcessInfo.processInfo.systemUptime + self.frameRemaining
                    try await Task.sleep(for: .seconds(self.frameRemaining))
                    let next = (self.frameIndex + 1) % self.frameCount
                    let image = try await decoder.frame(at: next)
                    let delay = try await decoder.delay(at: next)
                    try Task.checkCancellation()
                    self.frameIndex = next; self.frameRemaining = delay
                    self.layer?.contents = image
                }
            } catch is CancellationError { /* Explicit pause or surface disposal. */ }
            catch { self.pause(); self.onError?(error) }
        }
    }

    public func pause() {
        if state == .playing || state == .ready { state = .paused }
        isPlaying = false; player?.pause()
        applyAudio()
        if let frameDeadline { frameRemaining = max(0, frameDeadline - ProcessInfo.processInfo.systemUptime) }
        frameDeadline = nil
        animationTasks.values.forEach { $0.cancel() }
    }

    public func setAudio(_ value: AudioSettings) { audio = value; applyAudio() }
    public func prepareToResume() async throws {
        try Task.checkCancellation()
        guard state == .ready || state == .paused else { throw WallpaperError("原生媒体尚未就绪，无法恢复。") }
    }
    public func cancelResumePreparation() async throws { pause() }
    public func setTransitionGain(_ value: Double) { transitionGain = value; applyAudio() }
    public func setGlobalMute(_ value: Bool) { globallyMuted = value; applyAudio() }
    public func setAudioSuppressed(_ value: Bool) { audioSuppressed = value; applyAudio() }
    private func applyAudio() {
        player?.isMuted = globallyMuted || audio.isMuted || audioSuppressed || transitionGain == 0 || !isPlaying
        player?.volume = Float(audio.volume * transitionGain)
    }

    public func close() async throws {
        asynchronousClose = true
        let animations = Array(animationTasks.values)
        dispose()
        if preparationActive {
            state = .closing
            await withCheckedContinuation { preparationWaiters.append($0) }
        }
        for task in animations { await task.value }
        state = .closed
    }

    func dispose() {
        guard state != .closed else { return }
        state = .closing
        generation = UUID()
        audioSuppressed = true
        onError = nil
        pause()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        looper?.disableLooping(); looper = nil
        player?.removeAllItems(); videoLayer?.player = nil
        videoLayer?.removeFromSuperlayer(); videoLayer = nil; player = nil
        decoder = nil; layer?.contents = nil
        removeFromSuperview()
        if !asynchronousClose { state = .closed }
    }
}
