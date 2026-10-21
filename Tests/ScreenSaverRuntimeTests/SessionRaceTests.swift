import AppKit
import XCTest
import ScreenSaverCore
import WallpaperCore
import WallpaperNative
@testable import ScreenSaverRuntime

@MainActor
final class SessionRaceTests: XCTestCase {
    func testRestartStillReportsTheOldRunsAutomaticCloseFailure() async throws {
        let f = try await RuntimeFixture(test: self)
        let old = try await f.publish()
        let gate = RuntimeGate()
        var surfaces: [GatedNativeSurface] = []
        addTeardownBlock { @MainActor in
            gate.release()
            surfaces.forEach { $0.failClose = false }
        }
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit, close: surfaces.isEmpty ? gate : nil)
            surfaces.append(surface); return surface
        }
        let closeFailure = expectation(description: "Old close error stays observable after restart")
        session.onError = { _, error in
            if error.localizedDescription.contains("injected native close failure") { closeFailure.fulfill() }
        }
        session.start()
        try await eventually { session.state.phase == .playing }
        surfaces[0].failClose = true
        surfaces[0].onError?(WallpaperError("runtime playback failure"))
        try await eventually { gate.arrived }
        let new = try await f.publish()
        session.start()
        try await eventually { session.state.phase == .playing && session.state.generationID == new.generationID }
        gate.release()
        await fulfillment(of: [closeFailure], timeout: 1)
        XCTAssertEqual(session.state.phase, .playing)
        XCTAssertEqual(session.state.generationID, new.generationID)
        XCTAssertFalse(f.accesses[0].closed)
        let retained = try await f.store.collectGarbage()
        XCTAssertTrue(retained.retained.contains(old.generationID))
        surfaces[0].failClose = false
        try await session.stop().value
    }

    func testFailedCloseCallbackCanExplicitlyRetryTheRelease() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        var surface: GatedNativeSurface?
        let session = f.makeSession { size, fit in
            let native = GatedNativeSurface(size: size, fit: fit)
            native.failClose = true; surface = native; return native
        }
        session.start()
        try await eventually { session.state.phase == .playing }
        var retry: Task<Void, Error>?
        session.onStateChange = { state in
            if state.phase == .failed, retry == nil {
                surface?.failClose = false
                retry = session.stop()
            }
        }
        if case .success = await session.stop().result { XCTFail("First close must fail") }
        try await XCTUnwrap(retry).value
        XCTAssertEqual(surface?.closeCalls, 2)
        XCTAssertTrue(f.accesses[0].closed)
        XCTAssertEqual(session.state.phase, .stopped)
    }

    func testStoppingCallbackCanReenterStopWithoutDuplicatingTheCloseBarrier() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        var surfaces: [GatedNativeSurface] = []
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit, close: gate)
            surfaces.append(surface); return surface
        }
        session.start()
        try await eventually { session.state.phase == .playing }
        var nested: Task<Void, Error>?
        var reentered = false
        session.onStateChange = { state in
            if state.phase == .stopping, !reentered {
                reentered = true
                nested = session.stop()
            }
        }
        let stopped = session.stop()
        try await eventually { gate.arrived }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(surfaces[0].closeCalls, 1)
        XCTAssertFalse(f.accesses[0].closed)
        gate.release()
        try await stopped.value
        try await nested?.value
        XCTAssertEqual(surfaces[0].closeCalls, 1)
    }

    func testFirstFrameClockStartsAfterPreparationAndStopWaitsForLateCompletion() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish(count: 2)
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        var surfaces: [GatedNativeSurface] = []
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit, prepare: gate)
            surfaces.append(surface); return surface
        }
        session.start()
        try await eventually { gate.arrived }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(session.state.entryID)
        XCTAssertEqual(session.state.phase, .preparing)
        XCTAssertEqual(surfaces.count, 1)
        let stopped = session.stop()
        XCTAssertTrue(f.view.subviews.isEmpty)
        var released = false
        let observer = Task { try await stopped.value; released = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(released)
        XCTAssertFalse(f.accesses[0].closed)
        gate.release()
        try await observer.value
        XCTAssertTrue(f.accesses[0].closed)
        XCTAssertTrue(f.view.subviews.isEmpty)
        XCTAssertNil(surfaces[0].native.layer?.contents)
    }

    func testRapidRestartHasSeparateSlotsAndLateOldPreparationCannotPresent() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        var surfaces: [GatedNativeSurface] = []
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit, prepare: surfaces.isEmpty ? gate : nil)
            surfaces.append(surface); return surface
        }
        session.start()
        try await eventually { gate.arrived }
        let oldStop = session.stop()
        session.start()
        try await eventually { session.state.phase == .playing }
        XCTAssertEqual(surfaces.count, 2)
        XCTAssertFalse(f.accesses[0].closed)
        gate.release()
        try await oldStop.value
        XCTAssertEqual(session.state.phase, .playing)
        XCTAssertTrue(f.accesses[0].closed)
        XCTAssertFalse(f.accesses[1].closed)
        XCTAssertNil(surfaces[0].view.superview)
        XCTAssertNotNil(surfaces[1].view.superview)
        try await session.stop().value
    }

    func testStopDuringRealCrossfadeImmediatelyRevokesBothOutputs() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish(count: 2, transition: 0.4)
        var surfaces: [MediaSurface] = []
        let session = f.makeSession { size, fit in
            let surface = MediaSurface(size: size, fit: fit); surfaces.append(surface); return surface
        }
        session.start()
        try await eventually { surfaces.count == 2 && surfaces[1].view.alphaValue > 0 && surfaces[1].view.alphaValue < 1 }
        XCTAssertEqual(surfaces[0].view.alphaValue + surfaces[1].view.alphaValue, 1, accuracy: 0.001)
        let stopped = session.stop()
        XCTAssertTrue(f.view.subviews.isEmpty)
        XCTAssertTrue(surfaces.allSatisfy { $0.state != .playing })
        try await stopped.value
        XCTAssertTrue(surfaces.allSatisfy { $0.layer?.contents == nil })
    }

    func testCloseFailureKeepsLeaseAndCanBeExplicitlyRetried() async throws {
        let f = try await RuntimeFixture(test: self)
        let old = try await f.publish()
        var surfaces: [GatedNativeSurface] = []
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit); surface.failClose = true
            surfaces.append(surface); return surface
        }
        session.start()
        try await eventually { session.state.phase == .playing }
        _ = try await f.publish()
        if case .success = await session.stop().result { XCTFail("Close failure must surface") }
        XCTAssertEqual(session.state.phase, .failed)
        XCTAssertEqual(session.state.failure?.code, .resourceReleaseFailed)
        XCTAssertEqual(session.state.failure?.reasons.count, 1)
        XCTAssertEqual(diagnosticDescriptions(in: try XCTUnwrap(session.state.failure)),
                       ["injected native close failure"])
        XCTAssertFalse(f.accesses[0].closed)
        let busy = try await f.store.collectGarbage()
        XCTAssertTrue(busy.retained.contains(old.generationID))
        surfaces[0].failClose = false
        try await session.stop().value
        XCTAssertTrue(f.accesses[0].closed)
        let collected = try await f.store.collectGarbage()
        XCTAssertTrue(collected.removed.contains(old.generationID))
    }

    func testNativeFailureStopsInsteadOfSkippingToAnotherEntry() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish(count: 3)
        var surfaces: [MediaSurface] = []
        let session = f.makeSession { size, fit in
            let surface = MediaSurface(size: size, fit: fit); surfaces.append(surface); return surface
        }
        session.start()
        try await eventually { session.state.phase == .playing }
        surfaces[0].onError?(WallpaperError("native decoder failed"))
        try await eventually { session.state.phase == .failed && f.accesses[0].closed }
        XCTAssertEqual(session.state.failure?.code, .unexpected)
        XCTAssertEqual(session.state.failure?.diagnostic?.localizedDescription, "native decoder failed")
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertTrue(f.view.subviews.isEmpty)
    }

    func testPlaybackAndReleaseFailuresRemainOrderedInStructuredState() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish()
        var surface: GatedNativeSurface?
        let session = f.makeSession { size, fit in
            let value = GatedNativeSurface(size: size, fit: fit)
            value.failClose = true; surface = value; return value
        }
        session.start()
        try await eventually { session.state.phase == .playing }
        surface?.onError?(WallpaperError("playback failed first"))
        try await eventually { session.state.failure?.code == .resourceReleaseFailed }
        let failure = try XCTUnwrap(session.state.failure)
        XCTAssertEqual(diagnosticDescriptions(in: failure),
                       ["playback failed first", "injected native close failure"])
        surface?.failClose = false
        try await session.stop().value
    }

    private func diagnosticDescriptions(in failure: ScreenSaverFailure) -> [String] {
        (failure.diagnostic.map { [$0.localizedDescription] } ?? [])
            + failure.reasons.flatMap(diagnosticDescriptions)
    }
}
