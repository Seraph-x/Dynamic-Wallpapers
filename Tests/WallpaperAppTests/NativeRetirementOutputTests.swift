@testable import WallpaperNative
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

/// Real output from this test process, with a silent successor so any remaining
/// signal belongs to the outgoing fixture. No microphone or other-app capture.
@MainActor
final class NativeRetirementOutputTests: XCTestCase {
    func testNativeOutgoingReleasesPlaybackAndCannotSoundAfterSwitch() async throws {
        _ = NSApplication.shared
        let directory = TranscodeTestFixtures.root.appendingPathComponent(".build/verification/native-retirement-output/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outgoingURL = directory.appendingPathComponent("outgoing-with-audio.mp4")
        let source = TranscodeTestFixtures.root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        try await TranscodeTestFixtures.ffmpeg(["-i", source.path, "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", outgoingURL.path])
        let silentURL = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: silentURL) } catch { XCTFail(error.localizedDescription) } }
        let outgoing = try await MediaProbe.inspect(outgoingURL)
        let silent = try await MediaProbe.inspect(silentURL)
        let outgoingAudio = try await AVURLAsset(url: outgoingURL).loadTracks(withMediaType: .audio)
        let successorAudio = try await AVURLAsset(url: silentURL).loadTracks(withMediaType: .audio)
        guard !outgoingAudio.isEmpty, successorAudio.isEmpty else {
            throw WallpaperError("Native retirement fixtures must have one audible source and a silent successor")
        }
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main))
        defer { window.shutdown() }
        window.updateGeometry(frame: CGRect(x: 65, y: 65, width: 160, height: 90), scale: 1)
        window.setGlobalMute(false)
        window.orderBack(nil)
        window.onPlaybackError = { XCTFail($0.localizedDescription) }
        let observer = SystemAudioEvidence()
        let queue = DispatchQueue(label: "native.retirement.capture")
        let stream = try await capture(observer: observer, queue: queue)
        var capturing = false
        var windows: [NativeRetirementAudioWindow] = []
        var retirement: [NativeRetirementEvidence] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        defer {
            do {
                try observer.writeEvidence(to: directory.appendingPathComponent("capture.json"))
                try encoder.encode(windows).write(to: directory.appendingPathComponent("windows.json"))
                try encoder.encode(retirement).write(to: directory.appendingPathComponent("retirement.json"))
            } catch { XCTFail("Native retirement evidence: \(error)") }
        }
        do {
            try await stream.startCapture(); capturing = true
            try await waitForCapture(observer)
            try await window.prepare(item: outgoing, fit: .fit,
                                     entry: PlaylistEntry(mediaID: outgoing.id, audio: AudioSettings(volume: 0.8)))
            let oldSurface = try XCTUnwrap(window.contentView?.subviews.first as? MediaSurface)
            let oldLayer = try XCTUnwrap(oldSurface.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
            let oldPlayer = try XCTUnwrap(oldLayer.player as? AVQueuePlayer)
            // Also cleans up the deliberately reactivated player in the artifact-only negative control.
            defer { oldPlayer.pause(); oldPlayer.removeAllItems() }
            windows.append(try await observe("prepared", silent: true, observer: observer))
            let first = await window.transition(duration: 0, paused: false)
            XCTAssertTrue(first.didDisplay); XCTAssertNil(first.error)
            windows.append(try await observe("playing-positive", silent: false, observer: observer))
            let incomingEntry = PlaylistEntry(mediaID: silent.id, audio: AudioSettings(volume: 0.8))
            try await window.prepare(item: silent, fit: .fit, entry: incomingEntry)
            let transitioned = await window.transition(duration: 0.3, paused: false)
            XCTAssertTrue(transitioned.didDisplay); XCTAssertNil(transitioned.error)
            retirement.append(.verify(oldSurface, player: oldPlayer, layer: oldLayer, phase: "after-switch"))
            XCTAssertEqual(window.activeSurfaceCount, 1)
            windows.append(try await observe("after-switch", silent: true, observer: observer))
            window.setGlobalMute(true)
            windows.append(try await observe("current-muted", silent: true, observer: observer))
            window.setGlobalMute(false)
            windows.append(try await observe("current-unmuted", silent: true, observer: observer))
            window.setPaused(true)
            windows.append(try await observe("current-paused", silent: true, observer: observer))
            window.setPaused(false)
            window.updateAudio([incomingEntry.id: AudioSettings(volume: 1)])
            windows.append(try await observe("current-resumed", silent: true, observer: observer))
            retirement.append(.verify(oldSurface, player: oldPlayer, layer: oldLayer, phase: "after-current-controls"))
            window.shutdown()
            try await window.waitForClosing()
            XCTAssertEqual(window.activeSurfaceCount, 0)
            windows.append(try await observe("all-closed", silent: true, observer: observer))
            try await stopCapture(stream, queue: queue, observer: observer); capturing = false
            let snapshot = observer.snapshot()
            guard snapshot.errors.isEmpty else { throw WallpaperError(snapshot.errors.joined(separator: "; ")) }
            // Evaluate the original time windows after all callbacks drain, so late
            // delivery cannot remove end-of-window evidence from acceptance.
            let reports = try windows.map { try $0.analyze(snapshot.packets) }
            try encoder.encode(reports).write(to: directory.appendingPathComponent("analysis.json"))
            for report in reports {
                print("NATIVE_RETIREMENT_AUDIO phase=\(report.name) stableRMS=\(report.stableRMS) packets=\(report.stablePackets) lastNonzeroOffset=\(String(describing: report.lastNonzeroOffset)) gaps=[\(report.minGap),\(report.maxGap)]")
            }
            print("NATIVE_RETIREMENT_AUDIO EVIDENCE scope=own-process continuous=unverified physicalAcoustics=unverified artifacts=\(directory.path)")
        } catch {
            window.shutdown()
            do { try await window.waitForClosing() } catch { XCTFail("Native retirement window cleanup: \(error)") }
            if capturing {
                do { try await stopCapture(stream, queue: queue, observer: observer) }
                catch { XCTFail("Native retirement capture cleanup: \(error)") }
            }
            throw error
        }
    }

    private func capture(observer: SystemAudioEvidence, queue: DispatchQueue) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let ownApp = try XCTUnwrap(content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier })
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true; configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48000; configuration.channelCount = 2
        configuration.width = 2; configuration.height = 2
        let stream = SCStream(filter: SCContentFilter(display: try XCTUnwrap(content.displays.first),
            including: [ownApp], exceptingWindows: []), configuration: configuration, delegate: observer)
        try stream.addStreamOutput(observer, type: .audio, sampleHandlerQueue: queue)
        print("NATIVE_RETIREMENT_AUDIO scope=own-process pid=\(ownApp.processID)")
        return stream
    }

    private func waitForCapture(_ observer: SystemAudioEvidence) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while observer.snapshot().packets.isEmpty {
            let errors = observer.snapshot().errors
            guard errors.isEmpty else { throw WallpaperError(errors.joined(separator: "; ")) }
            guard ContinuousClock.now < deadline else { throw WallpaperError("Native retirement capture did not become ready") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func observe(_ name: String, silent: Bool, observer: SystemAudioEvidence) async throws -> NativeRetirementAudioWindow {
        let start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try await Task.sleep(for: .milliseconds(750))
        let end = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let snapshot = observer.snapshot()
        observer.recordWindow(.init(name: name, start: start, end: end,
                                    snapshotHost: snapshot.host, snapshotPacketCount: snapshot.packets.count))
        return .init(name: name, start: start, end: end, expectsSilence: silent)
    }

    private func stopCapture(_ stream: SCStream, queue: DispatchQueue, observer: SystemAudioEvidence) async throws {
        try await stream.stopCapture()
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        observer.markCaptureStoppedAndDrained()
    }

}
