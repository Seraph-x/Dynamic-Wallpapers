@testable import WallpaperNative
import AppKit
import AVFoundation
import CoreMedia
import XCTest
import WallpaperCore
@testable import WallpaperApp

/// Two real windows on the available NSScreen, not two invented physical displays.
@MainActor
final class HeterogeneousPlaybackTests: XCTestCase {
    func testMixedBackendsWaitForAllWindowsAndKeepEntryAudioAcrossCompletionBoundary() async throws {
        _ = NSApplication.shared
        let fixture = try await fixtures()
        var retirement: [NativeRetirementEvidence] = []
        defer {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(retirement).write(to: fixture.directory.appendingPathComponent("native-retirement.json"))
            } catch { XCTFail("Writing native retirement diagnostics: \(error)") }
        }
        let screen = try XCTUnwrap(NSScreen.main)
        let windows = [DesktopWindow(screen: screen), DesktopWindow(screen: screen)]
        windows[0].updateGeometry(frame: CGRect(x: 20, y: 20, width: 160, height: 90), scale: 1)
        windows[1].updateGeometry(frame: CGRect(x: 200, y: 20, width: 90, height: 160), scale: 2)
        let endpoints = windows.enumerated().map { index, window in WindowDiagnosticEndpoint(window: window, index: index) }
        let entry = PlaylistEntry(mediaID: fixture.target.id, audio: AudioSettings(volume: 0.2))
        var playlist = Playlist(name: "Isolated mixed-window diagnostic", entries: [entry], transition: 0)
        var commits: [UUID] = [], errors: [String] = []
        for (index, window) in windows.enumerated() {
            window.onPlaybackError = { errors.append("window[\(index)]: \($0.localizedDescription)") }
        }
        let session = PlaybackSession(playlist: playlist, media: [fixture.target], endpoints: endpoints,
            fit: .fit, autoAdvance: false, onCommit: { commits.append($0) }, onStatus: { _ in },
            onError: { errors.append($0.localizedDescription) })
        do {
            for (index, item) in [fixture.native, fixture.oldExtended].enumerated() {
                windows[index].setGlobalMute(false)
                try await windows[index].prepare(item: item, fit: .fit,
                    entry: PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.1)))
                let result = await windows[index].transition(duration: 0, paused: false)
                XCTAssertTrue(result.didDisplay); XCTAssertNil(result.error)
            }
            let oldNative = try XCTUnwrap(windows[0].contentView?.subviews.first as? MediaSurface)
            let oldLayer = try XCTUnwrap(oldNative.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
            let oldPlayer = try XCTUnwrap(oldLayer.player as? AVQueuePlayer)
            let oldMPV = try XCTUnwrap(windows[1].contentView?.subviews.first as? MPVSurface)
            endpoints[1].holdPreparation = true
            endpoints[1].holdCompletion = true
            session.start()
            try await waitUntil { endpoints.allSatisfy(\.prepared) }
            XCTAssertTrue(commits.isEmpty)
            XCTAssertTrue(endpoints.allSatisfy { $0.transitionStarted == nil })
            XCTAssertEqual(windows.map(\.activeSurfaceCount), [2, 2])
            XCTAssertTrue(oldNative.isPlaying); XCTAssertEqual(oldMPV.state, .playing)
            let pending = try windows.map { try XCTUnwrap($0.contentView?.subviews.last as? MPVSurface) }
            for surface in pending { XCTAssertEqual(surface.state, .ready); XCTAssertTrue(try surface.audioIsMuted()) }
            playlist.entries[0].audio.volume = 0.35
            session.update(playlist: playlist, media: [fixture.target])
            for surface in pending {
                XCTAssertEqual(try surface.playbackVolume(), 0.35, accuracy: 0.0001)
                XCTAssertTrue(try surface.audioIsMuted())
            }
            endpoints[1].releasePreparation()
            try await waitUntil { endpoints.allSatisfy { $0.windowCompleted != nil } }
            XCTAssertTrue(commits.isEmpty, "Real windows completed, but the group's final endpoint has not returned")
            XCTAssertTrue(session.isTransitioning)
            XCTAssertEqual(oldNative.state, .closed); XCTAssertEqual(oldMPV.state, .closed)
            // Retired AVPlayer flags can receive asynchronous framework reports.
            // Check released playback bindings; actual silence has a separate
            // own-process positive-control test in NativeRetirementOutputTests.
            retirement.append(.verify(oldNative, player: oldPlayer, layer: oldLayer, phase: "windows-completed"))
            XCTAssertEqual(windows.map(\.activeSurfaceCount), [1, 1])
            playlist.entries[0].audio = AudioSettings(isMuted: true, volume: 0.6)
            session.update(playlist: playlist, media: [fixture.target])
            for surface in pending {
                XCTAssertEqual(try surface.playbackVolume(), 0.6, accuracy: 0.0001)
                XCTAssertTrue(try surface.audioIsMuted(), "Completed window still belongs to the incoming entry")
            }
            retirement.append(.verify(oldNative, player: oldPlayer, layer: oldLayer, phase: "incoming-audio-updated"))
            endpoints[1].releaseCompletion()
            try await waitUntil { commits.count == 1 }
            XCTAssertEqual(commits, [entry.id])
            XCTAssertEqual(session.currentEntryID, entry.id)
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
            XCTAssertEqual(pending[0].currentImage?.width, 160)
            XCTAssertEqual(pending[0].currentImage?.height, 90)
            XCTAssertEqual(pending[1].currentImage?.width, 180)
            XCTAssertEqual(pending[1].currentImage?.height, 102)
            session.setPaused(true)
            XCTAssertTrue(pending.allSatisfy { $0.state == .paused })
            let positions = try pending.map { try $0.playbackPosition() }
            try await Task.sleep(for: .milliseconds(80))
            for (surface, position) in zip(pending, positions) {
                XCTAssertEqual(try surface.playbackPosition(), position, accuracy: 0.05)
            }
            try writeEvidence(endpoints, directory: fixture.directory, screen: screen)
            session.stop()
            try await close(windows)
            XCTAssertEqual(windows.map(\.activeSurfaceCount), [0, 0])
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        } catch {
            endpoints.forEach { $0.releasePreparation(); $0.releaseCompletion() }
            session.stop()
            do { try await close(windows) } catch { XCTFail("Mixed-window cleanup: \(error)") }
            throw error
        }
    }

    private func fixtures() async throws -> (directory: URL, native: MediaItem, oldExtended: MediaItem, target: MediaItem) {
        let root = TranscodeTestFixtures.root
        let directory = root.appendingPathComponent(".build/verification/heterogeneous-playback/\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = root.appendingPathComponent(".build/dependencies/mpv/fixtures/h264-aac.mkv")
        let nativeURL = directory.appendingPathComponent("native.mp4")
        try await TranscodeTestFixtures.ffmpeg(["-i", source.path, "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", nativeURL.path])
        let native = try await MediaProbe.inspect(nativeURL)
        let oldExtended = try await MediaProbe.inspect(root.appendingPathComponent(".build/dependencies/mpv/fixtures/mpeg4-mp3.avi"))
        let target = try await MediaProbe.inspect(source)
        return (directory, native, oldExtended, target)
    }

    private func writeEvidence(_ endpoints: [WindowDiagnosticEndpoint], directory: URL, screen: NSScreen) throws {
        let screenID = try XCTUnwrap(screen.wallpaperID)
        let report: [String: Any] = ["logicalEndpoints": endpoints.count, "actualWindows": endpoints.count,
            "physicalDisplayCount": NSScreen.screens.count, "physicalScreenID": screenID,
            "requestedRenderScales": [1, 2], "physicalHeterogeneousDisplays": "unverified",
            "audioEvidence": "backend parameters; no per-window PCM or physical-speaker measurement",
            "clockEvidence": "host call/return times; no cross-display frame lock assertion",
            "endpoints": endpoints.map { $0.events }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("windows.json"))
        print("HETEROGENEOUS_PLAYBACK logicalEndpoints=2 actualWindows=2 physicalDisplays=\(NSScreen.screens.count) renderScales=[1,2] oldBackends=[native,mpv] newBackends=[mpv,mpv] artifacts=\(directory.path)")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Mixed-window diagnostic timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private func close(_ windows: [DesktopWindow]) async throws {
        windows.forEach { $0.shutdown() }
        var errors: [String] = []
        for window in windows {
            do { try await window.waitForClosing() } catch { errors.append(error.localizedDescription) }
        }
        if !errors.isEmpty { throw WallpaperError(errors.joined(separator: "; ")) }
    }
}

/// Gates surround real window operations, solely to expose deterministic group boundaries.
@MainActor
private final class WindowDiagnosticEndpoint: PlaybackEndpoint {
    let window: DesktopWindow
    let index: Int
    var holdPreparation = false
    var holdCompletion = false
    private(set) var prepared = false
    private(set) var transitionStarted: Double?
    private(set) var windowCompleted: Double?
    private(set) var events: [[String: Any]] = []
    private var preparation: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    var releaseFailure: Error? { window.releaseFailure }
    init(window: DesktopWindow, index: Int) { self.window = window; self.index = index }
    func prepare(item: MediaItem, fit: ContentFit, entry: PlaylistEntry) async throws {
        try await window.prepare(item: item, fit: fit, entry: entry)
        prepared = true
        record("prepared")
        if holdPreparation { await withCheckedContinuation { preparation = $0 } }
        try Task.checkCancellation()
    }
    func transition(duration: Double, paused: Bool) async -> PlaybackTransitionResult {
        transitionStarted = record("transition-start")
        let result = await window.transition(duration: duration, paused: paused)
        windowCompleted = record("window-completed")
        if holdCompletion { await withCheckedContinuation { completion = $0 } }
        record("endpoint-return")
        return result
    }
    @discardableResult private func record(_ event: String) -> Double {
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        events.append(["window": index, "event": event, "host": host, "resources": window.activeSurfaceCount])
        return host
    }
    func releasePreparation() { holdPreparation = false; preparation?.resume(); preparation = nil }
    func releaseCompletion() { holdCompletion = false; completion?.resume(); completion = nil }
    func updateAudio(_ settings: [UUID: AudioSettings]) { window.updateAudio(settings) }
    func discardPreparation() { window.discardPreparation() }
    func setPaused(_ paused: Bool) { window.setPaused(paused) }
    func prepareToResume(requestID: UUID) async throws { try await window.prepareToResume(requestID: requestID) }
    func cancelResumePreparation(requestID: UUID) async throws { try await window.cancelResumePreparation(requestID: requestID) }
}
