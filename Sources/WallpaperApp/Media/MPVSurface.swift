import WallpaperNative
import AppKit
import MPVBridge
import WallpaperCore

struct ExtendedMediaMetadata: Equatable {
    let width: Int
    let height: Int
    let duration: Double
    let hardwareDecoder: String
}

@MainActor
final class MPVSurface: NSView, PlaybackSurface {
    var view: NSView { self }
    private(set) var state: PlaybackSurfaceState = .idle
    private(set) var currentImage: CGImage?
    private(set) var metadata: ExtendedMediaMetadata?
    private(set) var committedFrameCount = 0
    var onError: ((Error) -> Void)?
    var onDecoderChange: ((String) -> Void)?

    private var bridge: DWMPVBridge?
    private var generation = UUID()
    private var audio = AudioSettings()
    private var globallyMuted = true
    private var audioSuppressed = false
    private var transitionGain = 1.0
    private var preparation: CheckedContinuation<Void, Error>?
    private var preparationActive = false
    private var preparationWaiters: [CheckedContinuation<Void, Never>] = []
    private var timeoutTask: Task<Void, Never>?
    private var closeTask: Task<Void, Error>?

    init(size: CGSize, fit: ContentFit) {
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.contentsGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { nil }

    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws {
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
        do {
            try Task.checkCancellation()
            guard item.backend == .extended, item.kind == .video else {
                throw WallpaperError("扩展播放器只接受明确标记为 extended 的视频。")
            }
            let url = try ExtendedMediaProbe.validateURL(item.url)
            let width = bounds.width * scale, height = bounds.height * scale
            guard scale.isFinite, scale > 0, width.isFinite, height.isFinite,
                  width >= 1, height >= 1, width < CGFloat(Int32.max), height < CGFloat(Int32.max),
                  timeout.isFinite, timeout > 0 else { throw WallpaperError("扩展视频准备尺寸或超时无效。") }
            try EntryTiming.validateClockDuration(timeout)
            let bridge = DWMPVBridge(width: Int(width.rounded(.up)), height: Int(height.rounded(.up)), fill: fit == .fill)
            self.bridge = bridge
            layer?.contentsGravity = fit == .fill ? .resizeAspectFill : .resizeAspect
            let generation = self.generation
            try await waitForFrame(bridge: bridge, url: url, generation: generation, timeout: timeout)
            try Task.checkCancellation()
            guard self.generation == generation, state == .preparing else { throw CancellationError() }
            state = .ready
        } catch {
            let result = await beginRelease().result
            if case .failure(let releaseError) = result {
                throw WallpaperError("视频准备未完成，且播放器资源释放失败。",
                    diagnostic: "准备视频：\(String(describing: error as NSError))\n释放播放器：\(String(describing: releaseError as NSError))")
            }
            throw error
        }
    }

    private func waitForFrame(bridge: DWMPVBridge, url: URL, generation: UUID, timeout: Double) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                preparation = continuation
                bridge.startPath(url.path, frame: { [weak self] pixels, values in
                    self?.receive(pixels: pixels, values: values, generation: generation)
                }, failure: { [weak self] error in
                    guard let self, self.generation == generation else { return }
                    self.handleFailure(error)
                })
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        self?.finishPreparation(.failure(WallpaperError("视频加载超时（\(timeout) 秒）：\(url.lastPathComponent)。")))
                    } catch is CancellationError { /* First frame, cancellation, or close won. */ }
                    catch { self?.finishPreparation(.failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPreparation(.failure(CancellationError()))
            }
        }
    }

    private func receive(pixels: Data, values: [String: Any], generation: UUID) {
        guard self.generation == generation, [.preparing, .ready, .playing, .paused].contains(state) else { return }
        do {
            guard let width = values["width"] as? Int, let height = values["height"] as? Int,
                  let duration = values["duration"] as? Double, let hardware = values["hardwareDecoder"] as? String,
                  let renderWidth = values["renderWidth"] as? Int, let renderHeight = values["renderHeight"] as? Int,
                  width > 0, height > 0, duration.isFinite, duration > 0,
                  renderWidth > 0, renderHeight > 0, renderWidth <= Int.max / 4,
                  renderHeight <= Int.max / (renderWidth * 4), pixels.count == renderWidth * renderHeight * 4,
                  !hardware.isEmpty, let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: renderWidth, height: renderHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: renderWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw WallpaperError("libmpv 返回的真实画面或元数据无效。")
            }
            let decoderChanged = metadata?.hardwareDecoder != hardware
            metadata = ExtendedMediaMetadata(width: width, height: height, duration: duration, hardwareDecoder: hardware)
            currentImage = image
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
            committedFrameCount += 1
            if decoderChanged { onDecoderChange?(hardware) }
            finishPreparation(.success(()))
        } catch { handleFailure(error) }
    }

    private func finishPreparation(_ result: Result<Void, Error>) {
        guard let continuation = preparation else { return }
        preparation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        continuation.resume(with: result)
    }

    func play() {
        guard state == .ready || state == .paused, let bridge else { return }
        state = .playing
        do { try applyAudio(); try bridge.setPaused(false) }
        catch { handleFailure(error) }
    }

    func pause() {
        guard state == .ready || state == .playing, let bridge else { return }
        state = .paused
        do { try applyAudio(); try bridge.setPaused(true) }
        catch { handleFailure(error) }
    }

    func setAudio(_ value: AudioSettings) {
        do { try value.validate(); audio = value; try applyAudio() }
        catch { handleFailure(error) }
    }
    func prepareToResume() async throws {
        try Task.checkCancellation()
        guard state == .ready || state == .paused else { throw WallpaperError("扩展媒体尚未就绪，无法恢复。") }
    }
    func cancelResumePreparation() async throws { pause() }
    func setTransitionGain(_ value: Double) {
        transitionGain = value
        do { try applyAudio() } catch { handleFailure(error) }
    }
    func setGlobalMute(_ value: Bool) {
        globallyMuted = value
        do { try applyAudio() } catch { handleFailure(error) }
    }
    func setAudioSuppressed(_ value: Bool) {
        audioSuppressed = value
        do { try applyAudio() } catch { handleFailure(error) }
    }

    private func applyAudio() throws {
        guard let bridge, metadata != nil, state != .closing, state != .closed else { return }
        // mpv v0.38 audio_update_volume cubes volume/100; our shared audio setting
        // is a linear amplitude (AVPlayer/CEF). Convert at this backend boundary.
        try bridge.setMuted(globallyMuted || audio.isMuted || audioSuppressed || transitionGain == 0 || state != .playing,
                            volume: cbrt(audio.volume * transitionGain) * 100)
    }

    private func handleFailure(_ error: Error) {
        guard state != .closing, state != .closed else { return }
        if preparation != nil { finishPreparation(.failure(error)); return }
        state = .failed
        audioSuppressed = true
        var messages = [error.localizedDescription]
        if let bridge, metadata != nil {
            do { try bridge.setMuted(true, volume: 0) } catch { messages.append(error.localizedDescription) }
            do { try bridge.setPaused(true) } catch { messages.append(error.localizedDescription) }
        }
        onError?(WallpaperError(messages.joined(separator: "；")))
    }

    func audioIsMuted() throws -> Bool {
        guard let bridge, state != .closing, state != .closed else { throw WallpaperError("扩展播放器已关闭。") }
        return try bridge.flagProperty("mute").boolValue
    }
    func playbackPosition() throws -> Double { try numberProperty("time-pos") }
    func playbackVolume() throws -> Double { pow(try numberProperty("volume") / 100, 3) }
    private func numberProperty(_ name: String) throws -> Double {
        guard let bridge, state != .closing, state != .closed else { throw WallpaperError("扩展播放器已关闭。") }
        return try bridge.numberProperty(name).doubleValue
    }

    func close() async throws {
        let result = await beginRelease().result
        if preparationActive { await withCheckedContinuation { preparationWaiters.append($0) } }
        try result.get()
    }

    /// Resource teardown does not wait for prepare: its catch path awaits this same task.
    private func beginRelease() -> Task<Void, Error> {
        if let closeTask { return closeTask }
        var audioError: Error?
        if let bridge, metadata != nil {
            do { try bridge.setMuted(true, volume: 0) } catch { audioError = error }
        }
        state = .closing
        generation = UUID()
        audioSuppressed = true
        finishPreparation(.failure(CancellationError()))
        let bridge = self.bridge
        let task = Task { @MainActor in
            if let bridge { await withCheckedContinuation { continuation in bridge.close { continuation.resume() } } }
            self.bridge = nil
            self.currentImage = nil
            self.layer?.contents = nil
            self.removeFromSuperview()
            self.state = .closed
            if let audioError { throw audioError }
        }
        closeTask = task
        return task
    }
}
