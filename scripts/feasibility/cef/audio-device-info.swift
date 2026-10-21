import Foundation
import CoreAudio

func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             as type: T.Type) throws -> T {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                            mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { memory.deallocate() }
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, memory)
    guard status == noErr else { throw NSError(domain: "CoreAudioRead", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "object=\(object) selector=\(selector)"]) }
    guard size == MemoryLayout<T>.size else { throw NSError(domain: "CoreAudioSize", code: Int(size)) }
    return memory.load(as: T.self)
}
func streams(_ device: AudioObjectID) throws -> [AudioStreamID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
    guard status == noErr else { throw NSError(domain: "CoreAudioStreamsSize", code: Int(status)) }
    var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
    guard status == noErr else { throw NSError(domain: "CoreAudioStreams", code: Int(status)) }
    return ids
}
do {
    let device = try read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioDeviceID.self)
    let name = try read(device, kAudioObjectPropertyName, as: CFString.self)
    let rate = try read(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self)
    print("date=\(ISO8601DateFormatter().string(from: Date())) defaultOutputDevice=\(device) name=\(name) nominalRate=\(rate)")
    for (label, selector, scope) in [
        ("deviceLatency", kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput),
        ("safetyOffset", kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput),
        ("bufferFrameSize", kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)] {
        let frames = try read(device, selector, scope, as: UInt32.self)
        print("\(label) frames=\(frames) ms=\(Double(frames) / rate * 1000)")
    }
    for stream in try streams(device) {
        let frames = try read(stream, kAudioStreamPropertyLatency, as: UInt32.self)
        print("stream=\(stream) latencyFrames=\(frames) latencyMs=\(Double(frames) / rate * 1000)")
    }
} catch { fputs("ERROR: \(error)\n", stderr); exit(1) }
