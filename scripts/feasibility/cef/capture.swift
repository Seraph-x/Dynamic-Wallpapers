import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

final class AudioObserver: NSObject, SCStreamOutput, SCStreamDelegate {
    var readyPath: String?
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("CAPTURE error \(error)\n", stderr)
        exit(1)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        if let path = readyPath {
            do {
                try Data("ready".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                print("CAPTURE ready epoch=\(Date().timeIntervalSince1970)")
                readyPath = nil
            } catch {
                fputs("CAPTURE ready-write-error \(error)\n", stderr)
                exit(1)
            }
        }
        let count = CMBlockBufferGetDataLength(block)
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
              format.mSampleRate == 48000,
              count == CMSampleBufferGetNumSamples(sample) * 2 * MemoryLayout<Float>.size else {
            fputs("CAPTURE unexpected-audio-format\n", stderr); exit(1)
        }
        var bytes = [Float](repeating: 0, count: count / MemoryLayout<Float>.size)
        let status = bytes.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard status == noErr else { fputs("CAPTURE copy-error \(status)\n", stderr); exit(1) }
        let energy = bytes.reduce(0.0) { $0 + Double($1 * $1) }
        guard let captureClock = stream.synchronizationClock else {
            fputs("CAPTURE missing-synchronization-clock-error\n", stderr); exit(1)
        }
        let sampleTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let pts = CMTimeGetSeconds(sampleTime)
        let hostPTS = CMTimeGetSeconds(CMSyncConvertTime(sampleTime, from: captureClock, to: CMClockGetHostTimeClock()))
        guard hostPTS.isFinite else {
            fputs("CAPTURE invalid-clock-conversion-error\n", stderr); exit(1)
        }
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let epoch = Date().timeIntervalSince1970
        let frames = CMSampleBufferGetNumSamples(sample)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let nonzeroFrames = bytes.indices.filter { bytes[$0] != 0 }.map { planar ? $0 % frames : $0 / 2 }
        let lastNonzeroFrame = nonzeroFrames.max() ?? -1
        let firstNonzeroFrame = nonzeroFrames.min() ?? -1
        let firstNonzeroEpoch = firstNonzeroFrame >= 0 ? epoch + hostPTS - host + Double(firstNonzeroFrame) / format.mSampleRate : -1
        let lastNonzeroEpoch = lastNonzeroFrame >= 0 ? epoch + hostPTS - host + Double(lastNonzeroFrame) / format.mSampleRate : -1
        print("CAPTURE epoch=\(epoch) samples=\(bytes.count) rms=\(sqrt(energy / Double(max(1, bytes.count)))) pts=\(pts) hostPTS=\(hostPTS) clockOffset=\(hostPTS - pts) host=\(host) sampleEpoch=\(epoch + hostPTS - host) firstNonzeroFrame=\(firstNonzeroFrame) firstNonzeroEpoch=\(firstNonzeroEpoch) lastNonzeroFrame=\(lastNonzeroFrame) lastNonzeroEpoch=\(lastNonzeroEpoch)")
    }
}

@main struct Capture {
    static func main() async {
        do {
            print("CAPTURE permission-before=\(CGPreflightScreenCaptureAccess())")
            var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let enumerationDeadline = ContinuousClock.now + .seconds(10)
            while !content.applications.contains(where: { $0.bundleIdentifier == "local.dynamicwallpaper.cef-feasibility" }) {
                guard ContinuousClock.now < enumerationDeadline else { throw NSError(domain: "CEFProbeNotRunningAfter10Seconds", code: 2) }
                try await Task.sleep(for: .milliseconds(100))
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            guard let display = content.displays.first else { throw NSError(domain: "NoDisplay", code: 1) }
            let apps = content.applications.filter {
                $0.bundleIdentifier == "local.dynamicwallpaper.cef-feasibility"
            }
            guard !apps.isEmpty else { throw NSError(domain: "CEFProbeNotRunning", code: 2) }
            print("CAPTURE included=\(apps.map { "\($0.processID):\($0.applicationName)" })")
            let systemAudio = CommandLine.arguments.contains("--system-audio")
            let excludeOthers = CommandLine.arguments.contains("--exclude-other-apps")
            print("CAPTURE scope=\(systemAudio ? "system-audio-statistics" : excludeOthers ? "exclude-other-apps" : "probe-application")")
            let excluded = content.applications.filter { !apps.contains($0) }
            print("CAPTURE excluded-app-count=\(excludeOthers ? excluded.count : 0)")
            let filter = systemAudio
                ? SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                : excludeOthers
                    ? SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                    : SCContentFilter(display: display, including: apps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let observer = AudioObserver()
            observer.readyPath = ProcessInfo.processInfo.environment["CEF_CAPTURE_READY_PATH"]
            let stream = SCStream(filter: filter, configuration: config, delegate: observer)
            try stream.addStreamOutput(observer, type: .audio, sampleHandlerQueue: DispatchQueue(label: "cef.audio.capture"))
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(19))
            try await stream.stopCapture()
            print("CAPTURE complete epoch=\(Date().timeIntervalSince1970)")
        } catch {
            fputs("CAPTURE failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
