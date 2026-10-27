import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SceneSurfaceTests: XCTestCase {
    private let item = MediaItem(url: URL(fileURLWithPath: "/project/scene.json"), kind: .scene,
        width: 640, height: 360, backend: .scene,
        sceneProject: SceneProjectReference(root: URL(fileURLWithPath: "/project"), entry: "scene.json", representation: .loose))

    func testPrepareIsSilentAndPauseResumeRetainsOneScene() async throws {
        let factory = TestSceneFactory()
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fit, pageFactory: factory)
        surface.setGlobalMute(false)
        surface.setAudio(AudioSettings(volume: 0.8))
        surface.setTransitionGain(0.25)
        try await surface.prepare(item: item, scale: 2, fit: .fit)
        XCTAssertEqual(surface.state, .ready)
        XCTAssertEqual(factory.page.gains.last, 0)
        surface.play()
        await surface.waitForPlaybackCommand()
        XCTAssertEqual(surface.state, .playing)
        XCTAssertEqual(factory.page.gains.last ?? -1, 0.2, accuracy: 0.0001)
        let identity = try XCTUnwrap(surface.interactivePageID)
        surface.pause()
        XCTAssertEqual(factory.page.gains.last, 0, "Audio gates synchronously before the browser ack")
        try await surface.prepareToResume()
        XCTAssertEqual(surface.state, .ready)
        XCTAssertEqual(factory.page.gains.last, 0)
        XCTAssertNil(surface.interactivePageID)
        surface.play()
        await surface.waitForPlaybackCommand()
        XCTAssertEqual(factory.count, 1, "Pause must retain the engine and its clock")
        XCTAssertNotEqual(surface.interactivePageID, identity, "Pause invalidates input already queued by the desktop")
        XCTAssertEqual(factory.page.playing, [true, false, true])
        try await surface.close()
        XCTAssertEqual(factory.page.closeCount, 1)
        XCTAssertEqual(surface.state, .closed)
    }

    func testLatePlayAckCannotEnableOutputAfterPauseOrClose() async throws {
        let factory = TestSceneFactory()
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: factory)
        try await surface.prepare(item: item, scale: 1, fit: .fill)
        surface.setGlobalMute(false)
        factory.page.holdNextPlay = true
        surface.play()
        XCTAssertTrue(factory.page.playbackIntent)
        for _ in 0..<20 { await Task.yield() }
        surface.pause()
        XCTAssertFalse(factory.page.playbackIntent, "Capture demand must clear before a late play ack")
        XCTAssertEqual(factory.page.gains.last, 0)
        factory.page.finishPlay()
        try await surface.prepareToResume()
        XCTAssertEqual(surface.state, .ready)
        XCTAssertEqual(factory.page.gains.last, 0)
        try await surface.close()
        XCTAssertEqual(surface.state, .closed)
        surface.play()
        XCTAssertNil(surface.interactivePageID)
    }

    func testCloseDuringPreparationCannotMountOrRestartTheScene() async throws {
        let factory = TestSceneFactory()
        factory.page.holdPrepare = true
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: factory)
        let prepare = Task { try await surface.prepare(item: item, scale: 1, fit: .fill) }
        while factory.page.prepareContinuation == nil { await Task.yield() }
        try await surface.close()
        do { try await prepare.value; XCTFail("Expected cancelled preparation") } catch is CancellationError {}
        XCTAssertEqual(surface.state, .closed)
        XCTAssertTrue(surface.subviews.isEmpty)
        surface.play()
        XCTAssertTrue(factory.page.playing.isEmpty)
    }

    func testFailedPlayAckRemainsSilentAndReportsFailure() async throws {
        let factory = TestSceneFactory()
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: factory)
        try await surface.prepare(item: item, scale: 1, fit: .fill)
        surface.setGlobalMute(false)
        factory.page.playError = WallpaperError("engine failed")
        var failure: Error?
        surface.onError = { failure = $0 }
        surface.play()
        await surface.waitForPlaybackCommand()
        XCTAssertEqual(surface.state, .failed)
        XCTAssertNotNil(failure)
        XCTAssertEqual(factory.page.gains.last, 0)
        try await surface.close()
    }

    func testCloseFailureRemainsOwnedAndVisible() async throws {
        let factory = TestSceneFactory()
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: factory)
        try await surface.prepare(item: item, scale: 1, fit: .fill)
        factory.page.closeError = WallpaperError("close failed")
        do { try await surface.close(); XCTFail("Expected close failure") } catch {}
        XCTAssertEqual(surface.state, .failed)
        XCTAssertNotNil(surface.releaseFailure)
        XCTAssertEqual(factory.page.gains.last, 0)
    }

    func testPointerUsesNormalizedViewportAndRejectsStaleIdentity() async throws {
        let factory = TestSceneFactory()
        let surface = SceneSurface(size: CGSize(width: 320, height: 180), fit: .fill, pageFactory: factory)
        try await surface.prepare(item: item, scale: 2, fit: .fill)
        surface.play()
        await surface.waitForPlaybackCommand()
        let id = try XCTUnwrap(surface.interactivePageID)
        XCTAssertTrue(try surface.sendClick(at: CGPoint(x: 80, y: 45), clickCount: 1, expectedPageID: id))
        XCTAssertEqual(factory.page.pointer.last, CGPoint(x: 0.25, y: 0.25))
        surface.pause()
        XCTAssertThrowsError(try surface.sendClick(at: .zero, clickCount: 1, expectedPageID: id))
        try await surface.close()
    }
}

@MainActor
private final class TestSceneFactory: ScenePageMaking {
    let page = TestScenePage()
    var count = 0
    func makeScenePage(size: CGSize) throws -> any ScenePageSession { count += 1; return page }
}

@MainActor
private final class TestScenePage: ScenePageSession {
    var view = NSView()
    var onError: ((Error) -> Void)?
    var gains: [Double] = []
    var playing: [Bool] = []
    var pointer: [CGPoint] = []
    var closeCount = 0
    var closeError: Error?
    var holdPrepare = false
    var prepareContinuation: CheckedContinuation<Void, Error>?
    var playError: Error?
    var holdNextPlay = false
    var playbackIntent = false
    private var continuation: CheckedContinuation<Void, Error>?
    func prepare(item: MediaItem, scale: CGFloat, fit: ContentFit) async throws {
        if holdPrepare { try await withCheckedThrowingContinuation { prepareContinuation = $0 } }
    }
    func setGain(_ value: Double) throws { gains.append(value) }
    func setPlaybackIntent(_ value: Bool) { playbackIntent = value }
    func setPlaying(_ value: Bool) async throws {
        if let playError { throw playError }
        playing.append(value)
        if value && holdNextPlay {
            holdNextPlay = false
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }
    func finishPlay() { continuation?.resume(); continuation = nil }
    func sendPointer(at point: CGPoint, kind: String) throws { pointer.append(point) }
    func close() async throws {
        closeCount += 1
        prepareContinuation?.resume(throwing: CancellationError()); prepareContinuation = nil
        if let closeError { throw closeError }
    }
}
