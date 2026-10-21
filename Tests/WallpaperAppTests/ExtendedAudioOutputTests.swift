import AppKit
import CoreMedia
import ScreenCaptureKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

/// Captures only this test process. No microphone, other-app capture, or device writes.
@MainActor
final class ExtendedAudioOutputTests: XCTestCase {
    func testRealSystemOutputGainAndPlaybackGates() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 160, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownApp = try XCTUnwrap(content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier })
        let display = try XCTUnwrap(content.displays.first)
        print("MPV_AUDIO scope=own-process pid=\(ownApp.processID) physicalDisplays=\(content.displays.count)")
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48000; configuration.channelCount = 2
        configuration.width = 2; configuration.height = 2
        let observer = SystemAudioEvidence()
        let evidenceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/verification/mpv-audio")
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let evidenceURL = evidenceDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer {
            do { try observer.writeEvidence(to: evidenceURL) }
            catch { XCTFail("Writing audio evidence failed: \(error)") }
        }
        let stream = SCStream(filter: SCContentFilter(display: display, including: [ownApp], exceptingWindows: []),
                              configuration: configuration, delegate: observer)
        let captureQueue = DispatchQueue(label: "mpv.test.capture")
        try stream.addStreamOutput(observer, type: .audio, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        let surface = MPVSurface(size: CGSize(width: 160, height: 90), fit: .fit)
        window.contentView = surface
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while observer.snapshot().packets.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(observer.snapshot().packets.isEmpty, "Capture must be ready before loading media")
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
            surface.onError = { XCTFail($0.localizedDescription) }
            surface.setAudio(AudioSettings(volume: 0.2)); surface.setGlobalMute(false)
            try await surface.prepare(item: MediaItem(url: fixture, kind: .video, width: 320, height: 180,
                                                      duration: 2, backend: .extended), scale: 1, fit: .fit)
            _ = try await measure("prepared", observer: observer, silent: true)
            surface.play()
            let low = try await measure("volume-20", observer: observer, silent: false)
            surface.setAudio(AudioSettings(volume: 0.8))
            let high = try await measure("volume-80", observer: observer, silent: false)
            XCTAssertEqual(high / low, 4, accuracy: 0.4, "Steady sine fixture: actual output amplitude ratio")
            surface.setGlobalMute(true)
            _ = try await measure("global-mute", observer: observer, silent: true)
            surface.setGlobalMute(false); surface.setAudio(AudioSettings(isMuted: true, volume: 0.8))
            _ = try await measure("entry-mute", observer: observer, silent: true)
            surface.setAudio(AudioSettings(volume: 0.2)); surface.setAudioSuppressed(true)
            _ = try await measure("outgoing-suppressed", observer: observer, silent: true)
            surface.setAudioSuppressed(false)
            _ = try await measure("resume", observer: observer, silent: false)
            surface.pause()
            _ = try await measure("paused", observer: observer, silent: true)
            surface.play()
            _ = try await measure("before-close", observer: observer, silent: false)
            try await surface.close()
            _ = try await measure("closed", observer: observer, silent: true)
            try await stopCapture(stream, queue: captureQueue, observer: observer)
            XCTAssertTrue(observer.snapshot().errors.isEmpty, observer.snapshot().errors.joined(separator: "; "))
        } catch {
            do { try await surface.close() }
            catch { XCTFail("Surface cleanup failed: \(error)") }
            do { try await stopCapture(stream, queue: captureQueue, observer: observer) }
            catch { XCTFail("Capture cleanup failed: \(error)") }
            throw error
        }
    }

    private func stopCapture(_ stream: SCStream, queue: DispatchQueue, observer: SystemAudioEvidence) async throws {
        try await stream.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        observer.markCaptureStoppedAndDrained()
    }

    private func measure(_ name: String, observer: SystemAudioEvidence, silent: Bool) async throws -> Double {
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try await Task.sleep(for: .milliseconds(750))
        let end = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        // Measure stable gain separately; report ALL transition-tail evidence, never call it zero-tail.
        let snapshot = observer.snapshot()
        observer.recordWindow(.init(name: name, start: start, end: end, snapshotHost: snapshot.host,
                                    snapshotPacketCount: snapshot.packets.count))
        let packets = snapshot.packets.filter { $0.start >= start && $0.end <= end }
        let stable = packets.filter { $0.start >= start + 0.25 }
        XCTAssertGreaterThan(stable.count, 10, "\(name): capture coverage missing")
        let gaps = zip(packets, packets.dropFirst()).map { $1.start - $0.end }
        let maxGap = gaps.max() ?? .nan
        let minGap = gaps.min() ?? .nan
        // SCK timestamps show clock drift and sample-sized corrections. Do not turn
        // sampled RMS into a continuous/no-tail claim or silently tolerate the gaps.
        print("MPV_AUDIO_COVERAGE phase=\(name) minGapSeconds=\(minGap) maxGapSeconds=\(maxGap) continuous=unverified")
        XCTAssertLessThanOrEqual(try XCTUnwrap(stable.first).start, start + 0.28, "\(name): stable start coverage")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(stable.last).end, end - 0.10, "\(name): stable end coverage")
        let rms = sqrt(stable.reduce(0) { $0 + $1.energy } / Double(stable.reduce(0) { $0 + $1.samples }))
        let lastNonzero = packets.compactMap(\.lastNonzero).max()
        print("MPV_AUDIO phase=\(name) hostStart=\(start) hostEnd=\(end) stableRMS=\(rms) packets=\(packets.count) lastNonzeroOffset=\(lastNonzero.map { String($0 - start) } ?? "none-in-covered-packets")")
        if silent { XCTAssertEqual(rms, 0, "\(name): captured stable samples must be zero (continuous coverage unverified)") }
        else { XCTAssertGreaterThan(rms, 0.0001, "\(name): actual audible-path positive control missing") }
        return rms
    }
}

