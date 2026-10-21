import AppKit
import AVFoundation
import XCTest
import WallpaperCore
import WallpaperNative
@testable import ScreenSaverRuntime

@MainActor
final class PowerLifecycleTests: XCTestCase {
    func testStartingWithClosedLidDoesNotAcquireMediaOrCreateOutput() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let power = TestScreenSaverPower(state: .init(lidClosed: true))
        let session = f.makeSession()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        lifecycle.start()
        XCTAssertEqual(session.state.phase, .stopped)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(f.accesses.isEmpty)
        XCTAssertTrue(f.view.subviews.isEmpty)
        try await lifecycle.stop().value
    }

    func testLidCloseRevokesOutputAndReleasesDirectoryWithoutHostStop() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish(type: "com.compuserve.gif", frames: 2)
        var surface: MediaSurface?
        let session = f.makeSession { size, fit in
            let native = MediaSurface(size: size, fit: fit); surface = native; return native
        }
        let power = TestScreenSaverPower()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        power.emit(.init(lidClosed: true))
        XCTAssertTrue(f.view.subviews.isEmpty)
        XCTAssertNotEqual(surface?.state, .playing)
        try await eventually { f.accesses[0].closed }
        XCTAssertNil(surface?.layer?.contents)
        try await lifecycle.stop().value
    }

    func testWakeWaitsForAllPowerReasonsToClear() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let power = TestScreenSaverPower()
        let session = f.makeSession()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        power.emit(.init(lidClosed: true, displaySleeping: true))
        try await eventually { f.accesses[0].closed }
        power.emit(.init(displaySleeping: true))
        await Task.yield()
        XCTAssertEqual(f.accesses.count, 1)
        power.emit(.init())
        try await eventually { f.accesses.count == 2 && session.state.phase == .playing }
        try await lifecycle.stop().value
    }

    func testWakeWaitsForThePreviousNativeRelease() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        var surfaces: [GatedNativeSurface] = []
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit, close: surfaces.isEmpty ? gate : nil)
            surfaces.append(surface); return surface
        }
        let power = TestScreenSaverPower()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        power.emit(.init(systemSleeping: true))
        try await eventually { gate.arrived }
        power.emit(.init())
        await Task.yield()
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertFalse(f.accesses[0].closed)
        gate.release()
        try await eventually { surfaces.count == 2 && session.state.phase == .playing }
        XCTAssertTrue(f.accesses[0].closed)
        try await lifecycle.stop().value
    }

    func testHostStopDuringPendingWakeCannotRestartPlayback() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        let session = f.makeSession { GatedNativeSurface(size: $0, fit: $1, close: gate) }
        let power = TestScreenSaverPower()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        power.emit(.init(displaySleeping: true))
        try await eventually { gate.arrived }
        power.emit(.init())
        let stopped = lifecycle.stop()
        gate.release()
        try await stopped.value
        power.emit(.init())
        await Task.yield()
        XCTAssertEqual(f.accesses.count, 1)
        XCTAssertTrue(f.view.subviews.isEmpty)
        XCTAssertNil(power.onChange)
    }

    func testReleaseFailureIsReportedAndWakeDoesNotStartAnotherRun() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        var surface: GatedNativeSurface?
        let session = f.makeSession { size, fit in
            let native = GatedNativeSurface(size: size, fit: fit); surface = native; return native
        }
        let power = TestScreenSaverPower()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        var failures: [String] = []
        lifecycle.onError = { failures.append($0.localizedDescription) }
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        surface?.failClose = true
        addTeardownBlock { @MainActor in surface?.failClose = false }
        power.emit(.init(lidClosed: true))
        try await eventually { !failures.isEmpty }
        power.emit(.init())
        await Task.yield()
        XCTAssertEqual(f.accesses.count, 1)
        XCTAssertTrue(failures.contains { $0.contains("injected native close failure") })
        surface?.failClose = false
        try await lifecycle.stop().value
    }

    func testPowerObservationFailureIsVisibleAndDoesNotStartPlayback() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let power = TestScreenSaverPower()
        power.startError = WallpaperError("lid observation unavailable")
        let lifecycle = ScreenSaverPlaybackLifecycle(session: f.makeSession(), power: power)
        var failure: Error?
        lifecycle.onError = { failure = $0 }
        lifecycle.start()
        XCTAssertEqual(failure?.localizedDescription, "lid observation unavailable")
        XCTAssertTrue(f.accesses.isEmpty)
        try await lifecycle.stop().value
    }

    func testSleepingReleasesTheActualVideoPlayerAndAudioPipeline() async throws {
        let f = try await RuntimeFixture(test: self)
        let url = try await RuntimeVideoFixture.makeVideo()
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        try await f.publishVideo(url)
        var surface: MediaSurface?
        let session = f.makeSession { size, fit in
            let native = MediaSurface(size: size, fit: fit); surface = native; return native
        }
        let power = TestScreenSaverPower()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        let layer = try XCTUnwrap(surface?.layer?.sublayers?.compactMap { $0 as? AVPlayerLayer }.first)
        let player = try XCTUnwrap(layer.player)
        XCTAssertTrue(layer.isReadyForDisplay)
        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertFalse(player.isMuted)
        power.emit(.init(displaySleeping: true))
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(player.isMuted)
        XCTAssertTrue(f.view.subviews.isEmpty)
        try await eventually { f.accesses[0].closed }
        XCTAssertNil(layer.player)
        XCTAssertNil(player.currentItem)
        XCTAssertNil(layer.superlayer)
        try await eventually { layer.displayedPixelBuffer() == nil }
        try await lifecycle.stop().value
    }

    func testClosingLidDuringPreparationCannotRestoreALateFrame() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        let session = f.makeSession { GatedNativeSurface(size: $0, fit: $1, prepare: gate) }
        let power = TestScreenSaverPower()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        lifecycle.start()
        try await eventually { gate.arrived }
        power.emit(.init(lidClosed: true))
        XCTAssertTrue(f.view.subviews.isEmpty)
        gate.release()
        try await eventually { f.accesses[0].closed }
        XCTAssertTrue(f.view.subviews.isEmpty)
        XCTAssertEqual(session.state.phase, .stopped)
        try await lifecycle.stop().value
    }

    func testHostRestartWaitsForPreviousStopRelease() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        var surfaces: [GatedNativeSurface] = []
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit, close: surfaces.isEmpty ? gate : nil)
            surfaces.append(surface); return surface
        }
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: TestScreenSaverPower())
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        let stopped = lifecycle.stop()
        try await eventually { gate.arrived }
        lifecycle.start()
        XCTAssertEqual(f.accesses.count, 1)
        gate.release()
        try await stopped.value
        try await eventually { f.accesses.count == 2 && session.state.phase == .playing }
        try await lifecycle.stop().value
    }

    func testObservationFailureDuringPlaybackRevokesOutputAndReportsError() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let power = TestScreenSaverPower()
        let session = f.makeSession()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        var failure: Error?
        lifecycle.onError = { failure = $0 }
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        power.onError?(WallpaperError("lid state read failed"))
        XCTAssertTrue(f.view.subviews.isEmpty)
        XCTAssertEqual(failure?.localizedDescription, "lid state read failed")
        try await eventually { f.accesses[0].closed }
        power.emit(.init())
        XCTAssertEqual(f.accesses.count, 1)
        try await lifecycle.stop().value
    }

    func testRestartAfterObservationAndReleaseFailureRetriesCleanupBeforePlaying() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        var surfaces: [GatedNativeSurface] = []
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit)
            surfaces.append(surface); return surface
        }
        let power = TestScreenSaverPower()
        let lifecycle = ScreenSaverPlaybackLifecycle(session: session, power: power)
        var errors = 0
        lifecycle.onError = { _ in errors += 1 }
        lifecycle.start()
        try await eventually { session.state.phase == .playing }
        surfaces[0].failClose = true
        addTeardownBlock { @MainActor in surfaces.forEach { $0.failClose = false } }
        power.onError?(WallpaperError("power observation failed"))
        try await eventually { errors == 2 }
        XCTAssertFalse(f.accesses[0].closed)
        surfaces[0].failClose = false
        lifecycle.start()
        try await eventually { surfaces.count == 2 && session.state.phase == .playing }
        XCTAssertTrue(f.accesses[0].closed)
        XCTAssertEqual(surfaces[0].closeCalls, 2)
        try await lifecycle.stop().value
    }
}

@MainActor
final class TestScreenSaverPower: ScreenSaverPowerObserving {
    var onChange: ((ScreenSaverPowerState) -> Void)?
    var onError: ((Error) -> Void)?
    var state: ScreenSaverPowerState
    var startError: Error?
    init(state: ScreenSaverPowerState = .init()) { self.state = state }
    func start() throws -> ScreenSaverPowerState {
        if let startError { throw startError }
        return state
    }
    func stop() { onChange = nil; onError = nil }
    func emit(_ state: ScreenSaverPowerState) { self.state = state; onChange?(state) }
}
