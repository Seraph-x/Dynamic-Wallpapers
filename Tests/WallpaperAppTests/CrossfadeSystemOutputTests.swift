import AppKit
import CoreMedia
import ScreenCaptureKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class CrossfadeSystemOutputTests: XCTestCase {
    func testRealMPVFadesOutAndInAcrossNativeSurface() async throws {
        _ = NSApplication.shared
        let nativeURL = try await VideoIntegrationTests.makeVideo() // Self-made silent native video.
        defer { do { try FileManager.default.removeItem(at: nativeURL) } catch { XCTFail(error.localizedDescription) } }
        let native = try await MediaProbe.inspect(nativeURL)
        let extended = MediaItem(url: TranscodeTestFixtures.root.appendingPathComponent(
            ".build/dependencies/mpv/fixtures/h264-aac.mkv"), kind: .video,
            width: 320, height: 180, duration: 2, backend: .extended)
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main))
        window.updateGeometry(frame: CGRect(x: 45, y: 45, width: 160, height: 90), scale: 1)
        window.setGlobalMute(false)
        window.onPlaybackError = { XCTFail($0.localizedDescription) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownApp = try XCTUnwrap(content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier })
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.excludesCurrentProcessAudio = false
        config.sampleRate = 48000; config.channelCount = 2; config.width = 2; config.height = 2
        let observer = SystemAudioEvidence()
        let stream = SCStream(filter: SCContentFilter(display: try XCTUnwrap(content.displays.first),
            including: [ownApp], exceptingWindows: []), configuration: config, delegate: observer)
        let queue = DispatchQueue(label: "crossfade.test.capture")
        try stream.addStreamOutput(observer, type: .audio, sampleHandlerQueue: queue)
        let evidence = TranscodeTestFixtures.root.appendingPathComponent(".build/verification/crossfade-audio")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        defer {
            do { try observer.writeEvidence(to: evidence.appendingPathComponent(UUID().uuidString + ".json")) }
            catch { XCTFail("Evidence write failed: \(error)") }
        }
        try await stream.startCapture()
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while observer.snapshot().packets.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(observer.snapshot().packets.isEmpty, "Capture must be ready")
            try await prepare(extended, on: window)
            _ = await window.transition(duration: 0, paused: false)
            let baseline = try await stable("baseline", observer: observer, silent: false)
            try await prepare(native, on: window)
            let startOut = hostNow
            let out = await window.transition(duration: 0.8, paused: false)
            XCTAssertTrue(out.didDisplay); XCTAssertNil(out.error)
            _ = try await stable("endpoint-silent", observer: observer, silent: true)
            try verifyRamp("fade-out", start: startOut, observer: observer, baseline: baseline, rising: false)
            try await prepare(extended, on: window)
            let startIn = hostNow
            let incoming = await window.transition(duration: 0.8, paused: false)
            XCTAssertTrue(incoming.didDisplay); XCTAssertNil(incoming.error)
            _ = try await stable("incoming-full", observer: observer, silent: false)
            try verifyRamp("fade-in", start: startIn, observer: observer, baseline: baseline, rising: true)
            window.shutdown()
            try await window.waitForClosing()
            try await stop(stream, queue: queue, observer: observer)
            XCTAssertTrue(observer.snapshot().errors.isEmpty, observer.snapshot().errors.joined(separator: "; "))
        } catch {
            window.shutdown()
            do { try await window.waitForClosing() } catch { XCTFail("Window cleanup: \(error)") }
            do { try await stop(stream, queue: queue, observer: observer) } catch { XCTFail("Capture cleanup: \(error)") }
            throw error
        }
    }

    private var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    private func prepare(_ item: MediaItem, on window: DesktopWindow) async throws {
        try await window.prepare(item: item, fit: .fit,
            entry: PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.8)))
    }
    private func stop(_ stream: SCStream, queue: DispatchQueue, observer: SystemAudioEvidence) async throws {
        try await stream.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        observer.markCaptureStoppedAndDrained()
    }
    private func stable(_ name: String, observer: SystemAudioEvidence, silent: Bool) async throws -> Double {
        let start = hostNow
        try await Task.sleep(for: .milliseconds(750))
        let end = hostNow
        let snapshot = observer.snapshot()
        observer.recordWindow(.init(name: name, start: start, end: end,
            snapshotHost: snapshot.host, snapshotPacketCount: snapshot.packets.count))
        let packets = snapshot.packets.filter { $0.start >= start + 0.25 && $0.end <= end }
        XCTAssertGreaterThan(packets.count, 10, "\(name): stable coverage")
        XCTAssertLessThanOrEqual(try XCTUnwrap(packets.first).start, start + 0.28)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(packets.last).end, end - 0.10)
        let value = rms(packets)
        if silent { XCTAssertEqual(value, 0, "Endpoint captured stable samples must be silent") }
        else { XCTAssertGreaterThan(value, 0.0001, "Positive control") }
        return value
    }
    private func verifyRamp(_ name: String, start: Double, observer: SystemAudioEvidence,
                            baseline: Double, rising: Bool) throws {
        let snapshot = observer.snapshot()
        observer.recordWindow(.init(name: name, start: start, end: start + 0.8,
            snapshotHost: snapshot.host, snapshotPacketCount: snapshot.packets.count))
        // Fixed windows inside the existing 0.8s transition, no device delay compensation.
        let levels = try [0.10, 0.32, 0.58].map { offset -> Double in
            let lower = start + offset, upper = lower + 0.16
            let packets = snapshot.packets.filter { $0.start >= lower && $0.end <= upper }
            XCTAssertGreaterThanOrEqual(packets.count, 5, "\(name): ramp coverage")
            XCTAssertLessThanOrEqual(try XCTUnwrap(packets.first).start, lower + 0.03)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(packets.last).end, upper - 0.03)
            return rms(packets) / baseline
        }
        print("CROSSFADE_AUDIO \(name) normalizedRMS=\(levels) continuous=unverified physicalAcoustics=unverified")
        if rising {
            XCTAssertLessThan(levels[0], levels[1]); XCTAssertLessThan(levels[1], levels[2])
        } else {
            XCTAssertGreaterThan(levels[0], levels[1]); XCTAssertGreaterThan(levels[1], levels[2])
        }
        XCTAssertGreaterThan(levels[1], 0.1, "Must have actual intermediate output")
        XCTAssertLessThan(levels[1], 0.9, "Must fade rather than cut at endpoint")
    }
    private func rms(_ packets: [SystemAudioEvidence.Packet]) -> Double {
        sqrt(packets.reduce(0) { $0 + $1.energy } / Double(packets.reduce(0) { $0 + $1.samples }))
    }
}
