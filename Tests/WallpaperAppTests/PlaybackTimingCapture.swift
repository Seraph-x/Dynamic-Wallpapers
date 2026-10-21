import AppKit
import ScreenCaptureKit
import WallpaperCore

@MainActor
final class PlaybackTimingCapture {
    let recorder = PlaybackTimingRecorder()
    let processID: pid_t
    let physicalDisplayCount: Int
    private let video: SCStream
    private let audio: SCStream
    private let queue = DispatchQueue(label: "local.dynamicwallpaper.test.playback-timing")
    private var startedVideo = false
    private var startedAudio = false

    init(window: NSWindow, content: SCShareableContent) throws {
        let processID = ProcessInfo.processInfo.processIdentifier
        self.processID = processID
        physicalDisplayCount = content.displays.count
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
              target.owningApplication?.processID == processID,
              let application = content.applications.first(where: { $0.processID == processID }),
              let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) else {
            throw WallpaperError("Timing capture must find its own test window, process and display")
        }
        let videoConfiguration = SCStreamConfiguration()
        videoConfiguration.width = 160; videoConfiguration.height = 90
        videoConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        videoConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        videoConfiguration.showsCursor = false
        videoConfiguration.ignoreShadowsSingleWindow = true
        video = SCStream(filter: SCContentFilter(desktopIndependentWindow: target),
                         configuration: videoConfiguration, delegate: recorder)
        let audioConfiguration = SCStreamConfiguration()
        audioConfiguration.width = 2; audioConfiguration.height = 2
        audioConfiguration.capturesAudio = true
        audioConfiguration.excludesCurrentProcessAudio = false
        audioConfiguration.sampleRate = 48000; audioConfiguration.channelCount = 2
        audio = SCStream(filter: SCContentFilter(display: display, including: [application], exceptingWindows: []),
                         configuration: audioConfiguration, delegate: recorder)
        try video.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)
        try audio.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await video.startCapture(); startedVideo = true
        try await audio.startCapture(); startedAudio = true
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let evidence = recorder.snapshot()
            guard evidence.errors.isEmpty else { throw WallpaperError(evidence.errors.joined(separator: "; ")) }
            if !evidence.video.isEmpty, !evidence.packets.isEmpty { return }
            guard ContinuousClock.now < deadline else { throw WallpaperError("Timing capture did not become READY") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stop() async throws {
        var failures: [String] = []
        if startedAudio {
            do { try await audio.stopCapture(); startedAudio = false }
            catch { failures.append("Audio capture stop: \(error)") }
        }
        if startedVideo {
            do { try await video.stopCapture(); startedVideo = false }
            catch { failures.append("Video capture stop: \(error)") }
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        if !failures.isEmpty { throw WallpaperError(failures.joined(separator: "; ")) }
    }
}
