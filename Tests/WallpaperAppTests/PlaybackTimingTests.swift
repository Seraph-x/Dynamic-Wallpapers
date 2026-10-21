import AppKit
import CoreMedia
import ScreenCaptureKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class PlaybackTimingTests: XCTestCase {
    func testShortMPVVideoAndOwnProcessPCMTimeDiagnostic() async throws {
        _ = NSApplication.shared
        let fixture = try await PlaybackTimingFixture.make()
        print("PLAYBACK_TIMING artifacts=\(fixture.directory.path)")
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 160, height: 90),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.hasShadow = false
        window.orderBack(nil)
        defer { window.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let capture = try PlaybackTimingCapture(window: window, content: content)
        let surface = MPVSurface(size: CGSize(width: 160, height: 90), fit: .fit)
        var playbackErrors: [String] = []
        surface.onError = { playbackErrors.append($0.localizedDescription) }
        do {
            try await capture.start()
            print("PLAYBACK_TIMING READY pid=\(capture.processID) physicalDisplays=\(capture.physicalDisplayCount) video=own-window audio=own-process continuous=unverified pairing=ordinal-count-only identity=unverified")
            window.contentView = surface
            surface.setAudio(AudioSettings(volume: 0.5)); surface.setGlobalMute(false)
            try await surface.prepare(item: MediaItem(url: fixture.url, kind: .video, width: 160, height: 90,
                                                      duration: 3, backend: .extended), scale: 1, fit: .fit)
            let started = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            surface.play()
            // Three distinguishable bursts before the first loop, not a durability run.
            try await Task.sleep(for: .milliseconds(2700))
            surface.pause()
            try await surface.close()
            try await capture.stop()
            let evidence = capture.recorder.snapshot()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: fixture.directory.appendingPathComponent("capture.json"))
            XCTAssertTrue(playbackErrors.isEmpty, playbackErrors.joined(separator: "; "))
            XCTAssertTrue(evidence.errors.isEmpty, evidence.errors.joined(separator: "; "))
            let video = evidence.video.map { PulseSample(time: $0.displayHost, value: $0.level) }
            let offsets = try PulseTimingAnalysis.compare(video: video, audio: evidence.audio,
                                                          sourceOffsets: fixture.sourceOffsets)
            try encoder.encode(offsets).write(to: fixture.directory.appendingPathComponent("offsets.json"))
            XCTAssertEqual(offsets.count, 3)
            for (index, offset) in offsets.enumerated() {
                XCTAssertGreaterThan(offset.video.upperBound, started)
                XCTAssertGreaterThan(offset.audio.upperBound, started)
                print("PLAYBACK_TIMING pulse=\(index) audioMinusVideoMS=\(offset.audioMinusVideo * 1000) bracketMS=[\(offset.lowerBound * 1000),\(offset.upperBound * 1000)] sourceOffsetMS=\(offset.sourceOffset * 1000)")
            }
            let gaps = zip(evidence.packets, evidence.packets.dropFirst()).map { $1.start - $0.end }
            print("PLAYBACK_TIMING pcmGapSeconds=[\(gaps.min() ?? .nan),\(gaps.max() ?? .nan)] physicalSpeaker=unmeasured panelScanout=unmeasured synchronizationAcceptance=not-asserted")
        } catch {
            do { try await surface.close() } catch { XCTFail("Timing surface cleanup: \(error)") }
            do { try await capture.stop() } catch { XCTFail("Timing capture cleanup: \(error)") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(capture.recorder.snapshot()).write(to: fixture.directory.appendingPathComponent("capture-failure.json"))
            throw error
        }
    }
}
