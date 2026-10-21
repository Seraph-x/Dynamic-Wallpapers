import AVFoundation
import ScreenCaptureKit
import WallpaperCore

/// The video renderer accepts buffers off the main thread. Only the latest
/// pending buffer is retained while it applies backpressure to capture.
final class WallpaperMirrorFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Statistics: Sendable {
        var receivedFrames = 0
        var enqueuedFrames = 0
        var replacedFrames = 0
        var pendingFrames = 0
        var frameStatuses: [Int: Int] = [:]
        var latestDisplayTime: UInt64?
    }

    let queue = DispatchQueue(label: "wallpaper-mirror-frames", qos: .userInitiated)
    @MainActor var onFailure: ((Error, Bool) -> Void)?
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var accepting = true
    private var captureStopped = false
    private var requesting = false
    private var pending: CMSampleBuffer?
    private var counts = Statistics()
    private var statusObservation: NSKeyValueObservation?

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
        super.init()
        statusObservation = renderer.observe(\.status, options: [.new]) { [weak self] renderer, _ in
            if renderer.status == .failed {
                self?.report(renderer.error ?? WallpaperError("全屏壁纸视频层停止显示。"), streamStopped: false)
            }
        }
    }

    var isAcceptingFrames: Bool { lock.withLock { accepting } }
    var hasStoppedCapture: Bool { lock.withLock { captureStopped } }
    var statistics: Statistics { lock.withLock { counts } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard isAcceptingFrames else { return }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            report(WallpaperError("全屏壁纸收到无效的视频帧。"), streamStopped: false)
            return
        }
        lock.withLock {
            counts.frameStatuses[rawStatus, default: 0] += 1
            counts.latestDisplayTime = (attachments.first?[.displayTime] as? NSNumber)?.uint64Value
        }
        switch status {
        case .complete: receive(sample)
        case .idle, .started, .blank, .suspended: break
        case .stopped: captureDidStop(WallpaperError("全屏壁纸采集已意外停止。"))
        @unknown default: report(WallpaperError("无法识别全屏壁纸的视频帧状态。"), streamStopped: false)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureDidStop(error)
    }

    func captureDidStop(_ error: Error) {
        report(error, streamStopped: true)
    }

    @discardableResult
    func receive(_ sample: CMSampleBuffer) -> Result<Void, Error> {
        guard isAcceptingFrames else { return .failure(CancellationError()) }
        do {
            let frame = try Self.immediateFrame(sample)
            return lock.withLock {
                guard accepting else { return .failure(CancellationError()) }
                counts.receivedFrames += 1
                if pending != nil { counts.replacedFrames += 1 }
                pending = frame
                counts.pendingFrames = 1
                if renderer.isReadyForMoreMediaData { enqueuePending() }
                if pending != nil && !requesting {
                    requesting = true
                    renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.drainPending() }
                }
                return .success(())
            }
        } catch {
            report(error, streamStopped: false)
            return .failure(error)
        }
    }

    func invalidate() {
        lock.withLock {
            accepting = false
            pending = nil
            counts.pendingFrames = 0
            renderer.stopRequestingMediaData()
            requesting = false
        }
    }

    func finish() async {
        invalidate()
        statusObservation?.invalidate()
        statusObservation = nil
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        await withCheckedContinuation { continuation in
            renderer.flush(removingDisplayedImage: true) { continuation.resume() }
        }
    }

    private func drainPending() {
        lock.withLock {
            if accepting && renderer.isReadyForMoreMediaData { enqueuePending() }
            if pending == nil || !accepting {
                renderer.stopRequestingMediaData()
                requesting = false
            }
        }
    }

    private func enqueuePending() {
        guard let frame = pending else { return }
        pending = nil
        counts.pendingFrames = 0
        renderer.enqueue(frame)
        counts.enqueuedFrames += 1
    }

    private func report(_ error: Error, streamStopped: Bool) {
        let report = lock.withLock {
            // Release decisions cannot wait for the main-actor error notification.
            if streamStopped { captureStopped = true }
            guard accepting else { return false }
            accepting = false
            pending = nil
            counts.pendingFrames = 0
            return true
        }
        guard report else { return }
        Task { @MainActor [weak self] in self?.onFailure?(error, streamStopped) }
    }

    private static func immediateFrame(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard CMSampleBufferIsValid(sample), CMSampleBufferGetImageBuffer(sample) != nil else {
            throw WallpaperError("全屏壁纸视频帧缺少像素数据。")
        }
        var copied: CMSampleBuffer?
        let result = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleBufferOut: &copied)
        guard result == noErr, let copied,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(copied, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else {
            throw WallpaperError("无法准备全屏壁纸视频帧。", diagnostic: "CMSampleBufferCreateCopy: \(result)")
        }
        let info = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(info, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return copied
    }
}
