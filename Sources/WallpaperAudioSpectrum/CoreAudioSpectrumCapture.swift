import CoreAudio
import Foundation
import WallpaperCore

@available(macOS 14.2, *)
@MainActor
public final class CoreAudioSpectrumCapture: SystemAudioCapturing {
    private let resources = AudioTapResources()
    public init() {}
    public func start() async throws { try await Task.detached { [resources] in try resources.start() }.value }
    public func snapshot() throws -> AudioSpectrum { try resources.state.snapshot() }
    public func stop() async throws { try await Task.detached { [resources] in try resources.stop() }.value }
}

/// Callback/observer state survives its owner until Core Audio releases both blocks.
private final class AudioTapState: @unchecked Sendable {
    private let lock = NSLock()
    private var spectrum = AudioSpectrum.zero
    private var failure: Error?
    func snapshot() throws -> AudioSpectrum {
        try lock.withLock { if let failure { throw failure }; return spectrum }
    }
    func publish(_ value: AudioSpectrum) { lock.withLock { if failure == nil { spectrum = value } } }
    func fail(_ error: Error) { lock.withLock { if failure == nil { failure = error }; spectrum = .zero } }
}

/// start/stop are serialized by the controller; only `state` crosses callback queues.
@available(macOS 14.2, *)
private final class AudioTapResources: @unchecked Sendable {
    let state = AudioTapState()
    private let queue = DispatchQueue(label: "wallpaper.system-audio-spectrum")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var io: AudioDeviceIOProcID?
    private var started = false
    private struct Observation {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var observations: [Observation] = []

    func start() throws {
        do {
            var pid = getpid(), process = AudioObjectID(kAudioObjectUnknown)
            var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), "Resolve audio process")
            guard process != kAudioObjectUnknown else { throw WallpaperError("无法识别应用音频进程，不能安全排除壁纸声音。") }
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [process])
            description.name = "Dynamic Wallpaper Spectrum"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try Self.check(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap")
            let format = try Self.format(tap)
            try Self.validate(format)
            var uid: Unmanaged<CFString>?
            address = Self.address(kAudioTapPropertyUID); size = UInt32(MemoryLayout.size(ofValue: uid))
            try Self.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &uid), "Read audio tap UID")
            guard let uid else { throw WallpaperError("系统音频 Tap 缺少标识。") }
            let tapUID = uid.takeRetainedValue() as String
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Dynamic Wallpaper Spectrum",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "Create private audio device")
            let analyzer = try AudioSpectrumAnalyzer(sampleRate: format.mSampleRate)
            let state = self.state
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, input, _, _, _ in
                do {
                    let (left, right) = try Self.samples(input, format: format)
                    if let spectrum = try analyzer.append(left: left, right: right) { state.publish(spectrum) }
                } catch { state.fail(error) }
            }, "Create audio callback")
            try observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
            try observe(tap, kAudioTapPropertyFormat)
            try observe(device, kAudioDevicePropertyDeviceIsAlive)
            try Self.check(AudioDeviceStart(device, io), "Start system audio capture")
            started = true
        } catch {
            let initial = error
            do { try stop() } catch { throw WallpaperErrorGroup([initial, error]) }
            throw initial
        }
    }

    func stop() throws {
        var errors: [Error] = []
        func release(_ status: OSStatus, _ operation: String) -> Bool {
            do { try Self.check(status, operation); return true }
            catch { errors.append(error); return false }
        }
        if started, release(AudioDeviceStop(device, io), "Stop system audio capture") { started = false }
        var retained: [Observation] = []
        for var observation in observations {
            if !release(AudioObjectRemovePropertyListenerBlock(observation.object, &observation.address,
                queue, observation.block), "Remove audio device observer") { retained.append(observation) }
        }
        observations = retained
        // Destroying the callback also drains the synchronously dispatched IO block.
        if !started, let io, release(AudioDeviceDestroyIOProcID(device, io), "Release audio callback") { self.io = nil }
        if !started, io == nil, observations.isEmpty, device != kAudioObjectUnknown,
           release(AudioHardwareDestroyAggregateDevice(device), "Release private audio device") { device = AudioObjectID(kAudioObjectUnknown) }
        if device == kAudioObjectUnknown, observations.isEmpty, tap != kAudioObjectUnknown,
           release(AudioHardwareDestroyProcessTap(tap), "Release system audio tap") { tap = AudioObjectID(kAudioObjectUnknown) }
        if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
    }

    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws {
        var address = Self.address(selector)
        let state = self.state
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            state.fail(WallpaperError("音频设备或采样格式已更改，请重试系统音频响应。"))
        }
        try Self.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, block), "Observe audio device")
        observations.append(Observation(object: object, address: address, block: block))
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw WallpaperError("\(operation) failed (Core Audio OSStatus \(status)).") }
    }
    private static func format(_ object: AudioObjectID) throws -> AudioStreamBasicDescription {
        var value = AudioStreamBasicDescription(), address = address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Read audio format")
        guard size == MemoryLayout<AudioStreamBasicDescription>.size else { throw WallpaperError("系统音频属性长度无效。") }
        return value
    }
    private static func validate(_ format: AudioStreamBasicDescription) throws {
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0, format.mBitsPerChannel == 32,
              format.mChannelsPerFrame == 2, format.mBytesPerFrame == (planar ? 4 : 8) else {
            throw WallpaperError("系统音频不是受支持的双声道 Float32 PCM 格式。")
        }
    }
    private static func samples(_ input: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) throws -> ([Float], [Float]) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard buffers.count == (planar ? 2 : 1) else { throw WallpaperError("系统音频缓冲区数量无效。") }
        let stride = planar ? 1 : 2
        let bytes = Int(buffers[0].mDataByteSize)
        guard bytes % (4 * stride) == 0, buffers.allSatisfy({
            $0.mNumberChannels == stride && Int($0.mDataByteSize) == bytes && (bytes == 0 || $0.mData != nil)
        }) else { throw WallpaperError("系统音频缓冲区格式无效。") }
        guard bytes > 0 else { return ([], []) }
        let frames = bytes / (4 * stride)
        let a = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let b = planar ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : a.advanced(by: 1)
        var left = [Float](repeating: 0, count: frames), right = left
        for index in 0..<frames { left[index] = a[index * stride]; right[index] = b[index * stride] }
        return (left, right)
    }
}
