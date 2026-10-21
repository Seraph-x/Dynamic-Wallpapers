import XCTest
import AppKit
import ScreenSaverCore
import WallpaperCore
import WallpaperNative
@testable import ScreenSaverRuntime

@MainActor
final class SessionTests: XCTestCase {
    func testDelayedFirstFrameStillReceivesItsFullDwellTime() async throws {
        let f = try await RuntimeFixture(test: self)
        _ = try await f.publish(count: 2, seconds: 0.15)
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        var surfaces: [GatedNativeSurface] = []
        let session = f.makeSession { size, fit in
            let surface = GatedNativeSurface(size: size, fit: fit, prepare: surfaces.isEmpty ? gate : nil)
            surfaces.append(surface); return surface
        }
        session.start()
        try await eventually { gate.arrived }
        try await Task.sleep(for: .milliseconds(200))
        gate.release()
        try await eventually { session.state.phase == .playing }
        let started = ProcessInfo.processInfo.systemUptime
        try await eventually { surfaces.count == 2 }
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.13)
        try await session.stop().value
    }

    func testFullAndLoopTimingsUseRealAnimatedMediaDuration() async throws {
        for timing in [EntryTiming(mode: .full), EntryTiming(mode: .loops, loops: 2)] {
            let f = try await RuntimeFixture(test: self)
            let manifest = try await f.publish(count: 2, frames: 2, timing: timing)
            let session = f.makeSession()
            var times: [Double] = []
            session.onStateChange = { state in
                if state.phase == .playing { times.append(ProcessInfo.processInfo.systemUptime) }
            }
            session.start()
            try await eventually { times.count >= 2 }
            let expected = timing.duration(mediaDuration: manifest.files[0].duration)
            XCTAssertGreaterThanOrEqual(times[1] - times[0], expected - 0.01)
            try await session.stop().value
        }
    }

    func testMissingPublicationReportsFailureAndClosesDirectoryAccess() async throws {
        let f = try await RuntimeFixture(test: self)
        let session = f.makeSession()
        session.start()
        try await eventually { session.state.phase == .failed && f.accesses.first?.closed == true }
        XCTAssertEqual(session.state.failure?.code, .pointerUnavailable)
        XCTAssertTrue(f.view.subviews.isEmpty)
    }

    func testRealFirstFrameAndSingleEntryIsNotRebuiltAtItsDuration() async throws {
        let f = try await RuntimeFixture(test: self)
        let manifest = try await f.publish()
        var surfaces: [MediaSurface] = []
        let session = f.makeSession { size, fit in
            let surface = MediaSurface(size: size, fit: fit); surfaces.append(surface); return surface
        }
        session.start()
        session.start()
        try await eventually { session.state.phase == .playing }
        XCTAssertEqual(session.state.generationID, manifest.generationID)
        XCTAssertEqual(session.state.entryID, manifest.entries[0].id)
        XCTAssertNotNil(surfaces[0].layer?.contents)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(surfaces.count, 1)
        try await session.stop().value
        XCTAssertEqual(session.state.phase, .stopped)
        XCTAssertTrue(f.view.subviews.isEmpty)
        XCTAssertNil(surfaces[0].layer?.contents)
        XCTAssertTrue(f.accesses[0].closed)
    }

    func testOrderedAndShuffleUseIndependentCursorsAndRealFrames() async throws {
        for mode in [PlaybackMode.ordered, .shuffle] {
            let f = try await RuntimeFixture(test: self)
            let manifest = try await f.publish(count: 3, mode: mode)
            let session = f.makeSession()
            var displayed: [UUID] = []
            session.onStateChange = { state in
                if state.phase == .playing, let id = state.entryID, displayed.last != id { displayed.append(id) }
            }
            session.start()
            try await eventually { displayed.count >= 4 }
            if mode == .ordered { XCTAssertEqual(Array(displayed.prefix(3)), manifest.entries.map(\.id)) }
            else { XCTAssertEqual(Set(displayed.prefix(3)), Set(manifest.entries.map(\.id))) }
            try await session.stop().value
        }
    }

    func testRepeatOneUsesFirstProjectedEntryAndNeverRebuilds() async throws {
        let f = try await RuntimeFixture(test: self)
        let manifest = try await f.publish(count: 3, mode: .repeatOne)
        var count = 0
        let session = f.makeSession { size, fit in count += 1; return MediaSurface(size: size, fit: fit) }
        session.start()
        try await eventually { session.state.phase == .playing }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(session.state.entryID, manifest.entries.first?.id)
        XCTAssertEqual(count, 1)
        try await session.stop().value
    }

    func testRunningSessionPinsOldGenerationUntilNativeCloseActuallyReturns() async throws {
        let f = try await RuntimeFixture(test: self)
        let old = try await f.publish()
        let gate = RuntimeGate()
        addTeardownBlock { @MainActor in gate.release() }
        let session = f.makeSession { GatedNativeSurface(size: $0, fit: $1, close: gate) }
        session.start()
        try await eventually { session.state.phase == .playing }
        _ = try await f.publish()
        XCTAssertEqual(session.state.generationID, old.generationID)
        let stopped = session.stop()
        XCTAssertTrue(f.view.subviews.isEmpty)
        try await eventually { gate.arrived }
        let retained = try await f.store.collectGarbage()
        XCTAssertTrue(retained.retained.contains(old.generationID))
        XCTAssertFalse(f.accesses[0].closed)
        gate.release()
        try await stopped.value
        let collected = try await f.store.collectGarbage()
        XCTAssertTrue(collected.removed.contains(old.generationID))
        XCTAssertTrue(f.accesses[0].closed)
    }
}
