import CoreMedia
import CoreVideo
import ScreenCaptureKit
import WallpaperCore

/// Records only the selected test window and this XCTest process's PCM, never a microphone.
final class PlaybackTimingRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct VideoFrame: Codable {
        let sampleHost: Double
        let displayHost: Double
        let level: Double
    }
    struct AudioPacket: Codable {
        let start: Double
        let end: Double
        let frames: Int
    }
    struct Snapshot: Codable {
        var video: [VideoFrame] = []
        var audio: [PulseSample] = []
        var packets: [AudioPacket] = []
        var frameStatuses: [Int] = []
        var errors: [String] = []
    }
    private let lock = NSLock()
    private var evidence = Snapshot()

    func snapshot() -> Snapshot { lock.withLock { evidence } }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        record(error)
    }
    private func record(_ error: Error) {
        lock.withLock { evidence.errors.append(error.localizedDescription) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        do {
            guard let clock = stream.synchronizationClock else { throw WallpaperError("Missing SCK clock") }
            let host = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), from: clock,
                                         to: CMClockGetHostTimeClock()).seconds
            guard host.isFinite else { throw WallpaperError("Invalid SCK host PTS") }
            switch type {
            case .screen: try recordVideo(sample, host: host)
            case .audio: try recordAudio(sample, host: host)
            default: throw WallpaperError("Unexpected capture output type")
            }
        } catch { record(error) }
    }

    private func recordVideo(_ sample: CMSampleBuffer, host: Double) throws {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let info = attachments.first,
              let rawStatus = info[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) else {
            throw WallpaperError("Missing SCK frame status")
        }
        lock.withLock { evidence.frameStatuses.append(rawStatus) }
        guard status == .complete else { return }
        guard let ticks = info[.displayTime] as? UInt64, ticks > 0,
              let pixel = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else {
            throw WallpaperError("Missing WindowServer display timestamp or BGRA frame")
        }
        let displayHost = CMClockMakeHostTimeFromSystemUnits(ticks).seconds
        guard displayHost.isFinite else { throw WallpaperError("Invalid WindowServer host timestamp") }
        let statusCode = CVPixelBufferLockBaseAddress(pixel, .readOnly)
        guard statusCode == kCVReturnSuccess else { throw WallpaperError("Lock capture pixels: \(statusCode)") }
        defer {
            let result = CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            if result != kCVReturnSuccess { record(WallpaperError("Unlock capture pixels: \(result)")) }
        }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw WallpaperError("Missing capture pixels") }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        guard width >= 8, height >= 8 else { throw WallpaperError("Capture window is too small for pulse patch") }
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var level = 0.0
        for y in (height / 2 - 2)..<(height / 2 + 2) {
            for x in (width / 2 - 2)..<(width / 2 + 2) {
                let offset = y * stride + x * 4
                level += Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2])
            }
        }
        let frame = VideoFrame(sampleHost: host, displayHost: displayHost, level: level / (16 * 3 * 255))
        lock.withLock { evidence.video.append(frame) }
    }

    private func recordAudio(_ sample: CMSampleBuffer, host: Double) throws {
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2, format.mSampleRate == 48000 else {
            throw WallpaperError("Unexpected captured PCM format")
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        let count = CMBlockBufferGetDataLength(block)
        guard frames > 0, count == frames * 2 * MemoryLayout<Float>.size else {
            throw WallpaperError("Invalid captured PCM length")
        }
        var values = [Float](repeating: 0, count: frames * 2)
        let result = values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard result == noErr, values.allSatisfy(\.isFinite) else { throw WallpaperError("Invalid captured PCM samples") }
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        // RMS bins resolve burst edges without confusing the sine's zero crossings for silence.
        let binFrames = PulseTimingAnalysis.audioBinFrames
        let bins = stride(from: 0, to: frames, by: binFrames).map { start -> PulseSample in
            let end = min(start + binFrames, frames)
            var energy = 0.0
            for frame in start..<end {
                for channel in 0..<2 {
                    let value = Double(values[planar ? channel * frames + frame : frame * 2 + channel])
                    energy += value * value
                }
            }
            return PulseSample(time: host + Double(start) / 48000,
                               value: sqrt(energy / Double((end - start) * 2)),
                               duration: Double(end - start) / 48000)
        }
        lock.withLock {
            evidence.audio.append(contentsOf: bins)
            evidence.packets.append(AudioPacket(start: host, end: host + Double(frames) / 48000, frames: frames))
        }
    }
}
