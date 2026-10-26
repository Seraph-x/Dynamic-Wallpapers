import WallpaperAudioSpectrum
import AppKit
import AVFoundation
import CoreAudio
import WallpaperCore

/// Only authored tones are written. Captured system PCM is never stored.
@MainActor
enum SystemSpectrumEvidence {
    static func inventory(_ selector: AudioObjectPropertySelector) throws -> Set<AudioObjectID> {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            throw WallpaperError("Cannot inspect Core Audio resource inventory")
        }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw WallpaperError("Cannot read Core Audio resource inventory") }
        return Set(values)
    }

    static func makeTone(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144000)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            let frequency = channel == 0 ? 1000.0 : 4000.0
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][index] = 0.2 * Float(sin(2 * .pi * frequency * Double(index) / 48000))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func isAudioMarker(_ view: NSView, red: Bool) throws -> Bool {
        guard let contents = view.layer?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else {
            throw WallpaperError("No actual CEF pixels for audio marker")
        }
        let image = contents as! CGImage
        guard let data = image.dataProvider?.data else { throw WallpaperError("Cannot read CEF audio marker pixels") }
        let bytes = data as Data
        var matching = 0
        for y in Int(Double(image.height) * 0.85)..<image.height {
            for x in 0..<Int(Double(image.width) * 0.3) {
                let offset = y * image.bytesPerRow + x * 4
                if bytes[offset] < 80 && (red ? bytes[offset + 2] > 180 && bytes[offset + 1] < 80
                                        : bytes[offset + 1] > 180 && bytes[offset + 2] < 80) { matching += 1 }
            }
        }
        return matching > 100
    }

    static func wait(_ message: String, until predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while try !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError(message) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func run(project: SceneProjectReference, runtime: CEFApplicationRuntime, directory: URL) async throws {
        guard #available(macOS 14.2, *) else { throw WallpaperError("Real spectrum validation needs macOS 14.2+") }
        let taps = try inventory(kAudioHardwarePropertyTapList), devices = try inventory(kAudioHardwarePropertyDevices)
        let output = AVAudioEngine()
        let player = AVAudioPlayerNode()
        output.attach(player)
        let toneURL = directory.appendingPathComponent("authored-stereo-tone.wav")
        try makeTone(at: toneURL)
        let audioFile = try AVAudioFile(forReading: toneURL)
        output.connect(player, to: output.mainMixerNode, format: audioFile.processingFormat)
        try output.start()
        let controller = runtime.systemAudioSpectrum
        let receive = controller.onSpectrum
        var latest = AudioSpectrum.zero
        controller.onSpectrum = { value in latest = value; receive?(value) }
        defer { controller.onSpectrum = receive }
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: runtime)
        var external: Process?
        do {
            try await surface.prepare(item: MediaItem(url: project.entryURL, kind: .scene, width: 640, height: 360,
                backend: .scene, sceneProject: project), scale: 1, fit: .fill)
            let view = surface.subviews[0]
            controller.setEnabled(true)
            for cycle in 1...2 {
                surface.play(); await surface.waitForPlaybackCommand(); await controller.settled()
                if let failure = controller.failure { throw failure }
                guard controller.status == .capturing else { throw WallpaperError("System capture did not start") }
                try await Task.sleep(for: .milliseconds(250))
                try await wait("Audio marker was not silent before external tone") { try isAudioMarker(view, red: false) }
                player.scheduleFile(audioFile, at: nil, completionHandler: nil); player.play()
                try await Task.sleep(for: .milliseconds(400))
                guard try isAudioMarker(view, red: false) else { throw WallpaperError("Host audio was not excluded from the tap") }
                player.stop()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); process.arguments = [toneURL.path]
                try process.run(); external = process
                try await wait("Actual external tone did not reach CEF audio-reactive pixels") { try isAudioMarker(view, red: true) }
                // Authored 1 kHz / 4 kHz tones occupy these 64-band logarithmic bins.
                let leftBand = 36, rightBand = 49
                try await wait("Real stereo frequencies did not reach the expected bands") {
                    latest.left[leftBand] > 0.1 && latest.right[rightBand] > 0.1 &&
                        latest.left[rightBand] < 0.02 && latest.right[leftBand] < 0.02
                }
                controller.setEnabled(false); await controller.settled()
                try await wait("Disabling capture did not clear scene spectrum") { try isAudioMarker(view, red: false) }
                process.terminate()
                while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                external = nil
                surface.pause(); await surface.waitForPlaybackCommand(); await controller.settled()
                guard controller.failure == nil else { throw controller.failure! }
                guard try inventory(kAudioHardwarePropertyTapList) == taps,
                      try inventory(kAudioHardwarePropertyDevices) == devices else { throw WallpaperError("Core Audio tap or device leaked") }
                controller.setEnabled(true)
                print("SCENE_AUDIO PASS cycle=\(cycle) realExternalTone=1 ownAudioExcluded=1 disabledClears=1 resourcesReleased=1")
            }
            try await surface.close()
            await controller.settled()
            guard controller.status == .waiting else { throw WallpaperError("Closed scene still demands audio capture") }
            output.stop()
        } catch {
            if let external, external.isRunning { external.terminate() }
            output.stop()
            do { try await surface.close(); try await controller.shutdown() }
            catch let cleanup { throw WallpaperErrorGroup([error, cleanup]) }
            throw error
        }
    }
}
