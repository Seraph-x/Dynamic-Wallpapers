import Foundation
import CoreMedia
import ScreenCaptureKit

final class SystemAudioEvidence: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Packet: Codable {
        let start: Double
        let end: Double
        let callbackHost: Double
        let energy: Double
        let samples: Int
        let lastNonzero: Double?
    }
    struct Window: Codable {
        let name: String
        let start: Double
        let end: Double
        let snapshotHost: Double
        let snapshotPacketCount: Int
    }
    struct Evidence: Codable {
        let processID: Int32
        let continuous: String
        let captureStoppedAndDrained: Bool
        let packets: [Packet]
        let windows: [Window]
        let errors: [String]
    }
    private let lock = NSLock()
    private var packets: [Packet] = []
    private var windows: [Window] = []
    private var errors: [String] = []
    private var captureStoppedAndDrained = false
    func markCaptureStoppedAndDrained() {
        lock.lock(); captureStoppedAndDrained = true; lock.unlock()
    }
    func recordWindow(_ window: Window) {
        lock.lock(); windows.append(window); lock.unlock()
    }
    func writeEvidence(to url: URL) throws {
        let evidence = lock.withLock {
            Evidence(processID: ProcessInfo.processInfo.processIdentifier, continuous: "unverified",
                     captureStoppedAndDrained: captureStoppedAndDrained,
                     packets: packets, windows: windows, errors: errors)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: url, options: .withoutOverwriting)
        print("MPV_AUDIO_EVIDENCE path=\(url.path) packets=\(evidence.packets.count) windows=\(evidence.windows.count)")
    }
    func snapshot() -> (packets: [Packet], errors: [String], host: Double) {
        lock.lock(); defer { lock.unlock() }
        return (packets, errors, CMClockGetTime(CMClockGetHostTimeClock()).seconds)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { record(error.localizedDescription) }
    private func record(_ message: String) { lock.lock(); errors.append(message); lock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let callbackHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard let block = CMSampleBufferGetDataBuffer(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2, format.mSampleRate == 48000,
              let clock = stream.synchronizationClock else { record("Invalid PCM or missing capture clock"); return }
        let frames = CMSampleBufferGetNumSamples(sample)
        let count = CMBlockBufferGetDataLength(block)
        guard frames > 0, count == frames * 2 * MemoryLayout<Float>.size else { record("Invalid PCM length"); return }
        var values = [Float](repeating: 0, count: frames * 2)
        let status = values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
        }
        guard status == noErr, values.allSatisfy(\.isFinite) else { record("Invalid PCM copy or samples"); return }
        let start = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), from: clock,
                                     to: CMClockGetHostTimeClock()).seconds
        guard start.isFinite else { record("Invalid host timestamp"); return }
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let last = values.indices.filter { values[$0] != 0 }.map { planar ? $0 % frames : $0 / 2 }.max()
        let packet = Packet(start: start, end: start + Double(frames) / 48000,
                            callbackHost: callbackHost,
                            energy: values.reduce(0) { $0 + Double($1) * Double($1) }, samples: values.count,
                            lastNonzero: last.map { start + Double($0) / 48000 })
        lock.lock(); packets.append(packet); lock.unlock()
    }
}
