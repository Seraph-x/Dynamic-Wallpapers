@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SurfaceLifecycleTests: XCTestCase {
    func testDisposedNativeSurfaceCannotRestart() {
        let surface = MediaSurface(size: CGSize(width: 32, height: 32), fit: .fit)
        surface.dispose()
        surface.play()
        XCTAssertFalse(surface.isPlaying, "Disposed surfaces must reject late playback intent")
    }
}

extension SurfaceLifecycleTests {
    func testReplacementWaitsForClosingSurfaceAndRejectsLateCallbacks() async throws {
        let fixture = try makeWindow()
        let window = fixture.window
        defer { window.shutdown() }
        try await window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry)
        _ = await window.transition(duration: 0, paused: false)
        let visible = fixture.factory.surfaces[0]
        try await window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry)
        let cancelled = fixture.factory.surfaces[1]
        cancelled.holdClose = true
        let lateError = cancelled.onError
        window.onPlaybackError = { XCTFail("Invalidated callback escaped: \($0)") }
        window.discardPreparation()
        XCTAssertTrue(cancelled.suppressed, "Audio must shut before async close starts")
        XCTAssertEqual(window.activeSurfaceCount, 2)
        let replacement = Task { try await window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry) }
        await fulfillment(of: [cancelled.closeStarted], timeout: 1)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fixture.factory.surfaces.count, 2)
        XCTAssertEqual(window.activeSurfaceCount, 2, "Closing still consumes a slot")
        XCTAssertTrue(visible.view.superview === window.contentView)
        lateError?(WallpaperError("late backend failure"))
        cancelled.finishClose()
        try await replacement.value
        XCTAssertEqual(fixture.factory.surfaces.count, 3)
        XCTAssertEqual(window.activeSurfaceCount, 2)
    }

    func testLatePreparationCannotCommitAfterCancellation() async throws {
        let fixture = try makeWindow()
        fixture.factory.holdPrepare = true
        let window = fixture.window
        defer { window.shutdown() }
        let preparation = Task { try await window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry) }
        while fixture.factory.surfaces.isEmpty { await Task.yield() }
        let surface = fixture.factory.surfaces[0]
        await fulfillment(of: [surface.prepareStarted], timeout: 1)
        window.discardPreparation()
        surface.finishPrepare()
        do { try await preparation.value; XCTFail("Invalidated preparation succeeded") }
        catch is CancellationError { }
        _ = await window.transition(duration: 0, paused: false)
        XCTAssertFalse(surface.playing)
        XCTAssertEqual(window.activeSurfaceCount, 0)
    }

    func testOutgoingCloseKeepsResourceUntilCompletion() async throws {
        let fixture = try makeWindow()
        let window = fixture.window
        defer { window.shutdown() }
        try await window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry)
        _ = await window.transition(duration: 0, paused: false)
        let outgoing = fixture.factory.surfaces[0]
        outgoing.holdClose = true
        try await window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry)
        let transition = Task { await window.transition(duration: 0, paused: false) }
        await fulfillment(of: [outgoing.closeStarted], timeout: 1)
        XCTAssertEqual(window.activeSurfaceCount, 2)
        XCTAssertTrue(outgoing.suppressed)
        XCTAssertTrue(fixture.factory.surfaces[1].playing)
        let unavailable = await window.transition(duration: 0, paused: false)
        XCTAssertFalse(unavailable.didDisplay)
        XCTAssertNotNil(unavailable.error)
        outgoing.finishClose()
        let result = await transition.value
        XCTAssertTrue(result.didDisplay)
        XCTAssertNil(result.error)
        XCTAssertEqual(window.activeSurfaceCount, 1)
    }

    func testCloseFailureIsReportedAndDoesNotFreeResource() async throws {
        let fixture = try makeWindow()
        let window = fixture.window
        defer { window.shutdown() }
        try await window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry)
        let surface = fixture.factory.surfaces[0]
        surface.closeError = WallpaperError("close failed")
        let failure = expectation(description: "close failure is visible")
        window.onPlaybackError = { XCTAssertEqual($0.localizedDescription, "close failed"); failure.fulfill() }
        window.discardPreparation()
        await fulfillment(of: [failure], timeout: 1)
        XCTAssertEqual(window.activeSurfaceCount, 1)
        do {
            try await window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry)
            XCTFail("Replacement must not conceal failed release")
        } catch { XCTAssertEqual(error.localizedDescription, "close failed") }
        XCTAssertEqual(fixture.factory.surfaces.count, 1)
    }

    func testTransitionCannotUseUnfinishedPreparation() async throws {
        let fixture = try makeWindow()
        fixture.factory.holdPrepare = true
        defer { fixture.window.shutdown() }
        let preparation = Task { try await fixture.window.prepare(item: fixture.item, fit: .fit, entry: fixture.entry) }
        while fixture.factory.surfaces.isEmpty { await Task.yield() }
        let surface = fixture.factory.surfaces[0]
        await fulfillment(of: [surface.prepareStarted], timeout: 1)
        let result = await fixture.window.transition(duration: 0, paused: false)
        XCTAssertFalse(result.didDisplay)
        XCTAssertEqual(result.error?.localizedDescription, "待播媒体尚未提交首帧。")
        XCTAssertFalse(surface.playing, "A pending instance must commit a real frame before transition")
        surface.finishPrepare()
        try await preparation.value
    }

    func testRebindingScreenWaitsForOldWindowClose() async throws {
        _ = NSApplication.shared
        let factory = ControlledFactory()
        let coordinator = DesktopCoordinator(surfaceFactory: factory)
        defer { coordinator.shutdown() }
        var library = Library.empty
        let item = MediaItem(url: URL(fileURLWithPath: "/lifecycle.png"), kind: .image, width: 32, height: 32)
        library.media = [item]
        library.playlists[0].entries = [PlaylistEntry(mediaID: item.id)]
        library.playlists[0].transition = 0
        library.displays = [DisplayBinding(id: try XCTUnwrap(NSScreen.main?.wallpaperID), playlistID: library.playlists[0].id)]
        let committed = expectation(description: "initial commit")
        coordinator.onCommit = { _, _ in committed.fulfill() }
        coordinator.onError = { XCTFail($0.localizedDescription) }
        coordinator.reconcile(library)
        await fulfillment(of: [committed], timeout: 1)
        let old = factory.surfaces[0]
        old.holdClose = true
        var unbound = library
        unbound.displays = []
        coordinator.reconcile(unbound)
        await fulfillment(of: [old.closeStarted], timeout: 1)
        let rebound = expectation(description: "rebound commit")
        coordinator.onCommit = { _, _ in rebound.fulfill() }
        coordinator.reconcile(library)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(factory.surfaces.count, 1, "A new window must wait for the retired window's resources")
        old.finishClose()
        await fulfillment(of: [rebound], timeout: 1)
        XCTAssertEqual(factory.surfaces.count, 2)
    }

    func testNativeCloseWaitsForInFlightPreparation() async throws {
        let url = try await VideoIntegrationTests.makeVideo()
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail(error.localizedDescription) } }
        let item = try await MediaProbe.inspect(url)
        let surface = MediaSurface(size: CGSize(width: 32, height: 32), fit: .fit)
        var preparationFinished = false
        let preparing = Task {
            do { try await surface.prepare(item: item, scale: 1, fit: .fit); XCTFail("Closed preparation succeeded") }
            catch is CancellationError { }
            catch { XCTFail(error.localizedDescription) }
            preparationFinished = true
        }
        while surface.state == .idle { await Task.yield() }
        try await surface.close()
        XCTAssertTrue(preparationFinished, "Close must wait for the in-flight native prepare operation")
        XCTAssertEqual(surface.state, .closed)
        await preparing.value
    }

    func testPreviewCloseSuppressesImmediatelyAndWaitsForRelease() async throws {
        let factory = ControlledFactory()
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        let coordinator = LivePreview.Coordinator(lifetime: lifetime, onError: { XCTFail($0.localizedDescription) })
        let item = MediaItem(url: URL(fileURLWithPath: "/preview.png"), kind: .image, width: 32, height: 32)
        coordinator.start(item: item, host: NSView(frame: CGRect(x: 0, y: 0, width: 32, height: 32)))
        await coordinator.task?.value
        let surface = try XCTUnwrap(factory.surfaces.first)
        surface.holdClose = true
        LivePreview.dismantleNSView(NSView(), coordinator: coordinator)
        XCTAssertTrue(surface.suppressed)
        await fulfillment(of: [surface.closeStarted], timeout: 1)
        XCTAssertNotNil(coordinator.surface, "Closing preview must retain its backend")
        surface.finishClose()
        try await coordinator.closeTask?.value
        XCTAssertNil(coordinator.surface)
    }

    func testClosedWindowReportsTransitionFailure() async throws {
        let fixture = try makeWindow()
        fixture.window.shutdown()
        let result = await fixture.window.transition(duration: 0, paused: false)
        XCTAssertFalse(result.didDisplay)
        XCTAssertEqual(result.error?.localizedDescription, "目标显示器窗口已关闭。")
    }

    func testFactoryRejectsUnavailableBackend() throws {
        for backend in [MediaBackend.web] {
            let item = MediaItem(url: URL(fileURLWithPath: "/missing"), kind: .video,
                                 width: 32, height: 32, backend: backend)
            XCTAssertThrowsError(try SurfaceFactory().makeSurface(item: item, size: .zero, fit: .fit))
        }
    }

    private func makeWindow() throws -> (window: DesktopWindow, factory: ControlledFactory, item: MediaItem, entry: PlaylistEntry) {
        _ = NSApplication.shared
        let factory = ControlledFactory()
        let window = DesktopWindow(screen: try XCTUnwrap(NSScreen.main), surfaceFactory: factory)
        let item = MediaItem(url: URL(fileURLWithPath: "/lifecycle.png"), kind: .image, width: 32, height: 32)
        return (window, factory, item, PlaylistEntry(mediaID: item.id))
    }
}

@MainActor
final class ControlledFactory: SurfaceMaking {
    var surfaces: [ControlledSurface] = []
    var holdPrepare = false
    func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
        let surface = ControlledSurface()
        surface.holdPrepare = holdPrepare
        surfaces.append(surface)
        return surface
    }
}

@MainActor
final class ControlledSurface: PlaybackSurface {
    let view = NSView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
    var state: PlaybackSurfaceState = .idle
    var onError: ((Error) -> Void)?
    var suppressed = false
    var playing = false
    var holdClose = false
    var holdPrepare = false
    var closeError: Error?
    var prepareError: Error?
    var audio = AudioSettings()
    var globallyMuted = true
    let closeStarted = XCTestExpectation(description: "close started")
    let prepareStarted = XCTestExpectation(description: "prepare started")
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws {
        state = .preparing
        if holdPrepare {
            await withCheckedContinuation { prepareContinuation = $0; prepareStarted.fulfill() }
        } else { prepareStarted.fulfill() }
        if let prepareError { state = .failed; throw prepareError }
        state = .ready
    }
    func play() { playing = true; state = .playing }
    func pause() { playing = false; state = .paused }
    func prepareToResume() async throws { try Task.checkCancellation() }
    func cancelResumePreparation() async throws { pause() }
    func setAudio(_ value: AudioSettings) { audio = value }
    func setTransitionGain(_ value: Double) {}
    func setGlobalMute(_ value: Bool) { globallyMuted = value }
    func setAudioSuppressed(_ value: Bool) { suppressed = value }
    func close() async throws {
        state = .closing
        if holdClose { await withCheckedContinuation { closeContinuation = $0; closeStarted.fulfill() } }
        else { closeStarted.fulfill() }
        if let closeError { state = .failed; throw closeError }
        playing = false
        view.removeFromSuperview()
        state = .closed
    }
    func finishClose() { closeContinuation?.resume(); closeContinuation = nil }
    func finishPrepare() { prepareContinuation?.resume(); prepareContinuation = nil }
}
