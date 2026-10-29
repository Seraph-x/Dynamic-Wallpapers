import XCTest
import WallpaperCore
@testable import WallpaperMediaIntegration

@MainActor
final class SystemMediaControllerTests: XCTestCase {
    final class WeakController {
        weak var value: SystemMediaController?
        init(_ value: SystemMediaController?) { self.value = value }
    }
    actor Service: SystemMediaServicing {
        var reads: [(SystemMediaSource, Bool)] = []
        var controls: [SystemMediaCommand] = []
        var result: SystemMediaReadResult?
        var failure: SystemMediaError?
        var pending: CheckedContinuation<SystemMediaReadResult, Never>?
        var hold = false
        var holdControl = false
        var controlPending: CheckedContinuation<Void, Never>?
        func setResult(_ value: SystemMediaReadResult?) { result = value }
        func setFailure(_ value: SystemMediaError?) { failure = value }
        func holdNext() { hold = true }
        func holdNextControl() { holdControl = true }
        func isControlPending() -> Bool { controlPending != nil }
        func releaseControl() { controlPending?.resume(); controlPending = nil }
        func isPending() -> Bool { pending != nil }
        func release(_ value: SystemMediaReadResult) { pending?.resume(returning: value); pending = nil }
        func read(source: SystemMediaSource, requestAuthorization: Bool) async throws -> SystemMediaReadResult {
            reads.append((source, requestAuthorization))
            if let failure { throw failure }
            if hold { hold = false; return await withCheckedContinuation { pending = $0 } }
            return try result ?? .current(SystemMediaSnapshot(source: source, trackID: "one", state: .playing,
                title: "Track", artist: "Artist", album: "Album", albumArtist: nil, position: 1, duration: 20))
        }
        func perform(_ command: SystemMediaCommand, source: SystemMediaSource) async throws {
            controls.append(command)
            if holdControl { holdControl = false; await withCheckedContinuation { controlPending = $0 } }
            if let failure { throw failure }
        }
    }

    func testDefaultOffAndSharedDemandNeverPromptImplicitly() async throws {
        let service = Service()
        let controller = SystemMediaController(service: service, pollInterval: 3600)
        let a = UUID(), b = UUID()
        controller.setPlaying(a, true); await controller.settled()
        XCTAssertEqual(controller.status, .disabled)
        let empty = await service.reads; XCTAssertTrue(empty.isEmpty)
        let active = SystemMediaController(service: service, pollInterval: 3600)
        active.configure(source: .music); await active.settled()
        let idle = await service.reads; XCTAssertTrue(idle.isEmpty)
        active.setPlaying(a, true); await active.settled()
        active.setPlaying(b, true); await active.settled()
        let reads = await service.reads
        XCTAssertEqual(reads.count, 1); XCTAssertFalse(reads[0].1)
        XCTAssertEqual(active.status, .available)
        active.setPlaying(a, false); XCTAssertNotNil(active.snapshot)
        active.setPlaying(b, false); XCTAssertNil(active.snapshot)
        XCTAssertEqual(active.status, .waitingForPlayback)
        await controller.shutdown(); await active.shutdown()
    }

    func testOnlyExplicitAuthorizeRequestsConsentAndDoesNotRetainIdleMetadata() async throws {
        let service = Service()
        let active = SystemMediaController(service: service, pollInterval: 3600)
        active.configure(source: .spotify)
        await active.authorize()
        let reads = await service.reads
        XCTAssertEqual(reads.count, 1); XCTAssertTrue(reads[0].1)
        XCTAssertEqual(active.status, .waitingForPlayback); XCTAssertNil(active.snapshot)
        await active.shutdown()
    }

    func testOldSourceReadCannotPublishAfterSwitchOrDisable() async throws {
        let service = Service()
        let active = SystemMediaController(service: service, pollInterval: 3600)
        await service.holdNext()
        active.configure(source: .music); active.setPlaying(UUID(), true)
        try await waitUntil { await service.isPending() }
        active.configure(source: .spotify)
        let old = try SystemMediaSnapshot(source: .music, trackID: "old", state: .playing,
            title: "Old", artist: "", album: "", albumArtist: nil, position: 0, duration: 1)
        await service.release(.current(old)); await active.settled()
        XCTAssertEqual(active.snapshot?.source, .spotify)
        active.configure(source: .disabled)
        XCTAssertNil(active.snapshot); XCTAssertEqual(active.status, .disabled)
        await active.shutdown()
    }

    func testDeniedAndFailureStayVisibleUntilExplicitRetry() async throws {
        let service = Service()
        let controller = SystemMediaController(service: service, pollInterval: 3600)
        await service.setResult(.authorizationDenied)
        controller.configure(source: .music); controller.setPlaying(UUID(), true)
        await controller.settled()
        XCTAssertEqual(controller.status, .authorizationDenied); XCTAssertNil(controller.snapshot)
        await controller.refresh()
        var reads = await service.reads; XCTAssertEqual(reads.count, 1)
        await service.setResult(nil); await controller.authorize()
        XCTAssertEqual(controller.status, .available)
        await service.setFailure(.invalidResponse("broken")); await controller.refresh()
        XCTAssertEqual(controller.status, .failed); XCTAssertNil(controller.snapshot)
        XCTAssertNotNil(controller.failure)
        await service.setFailure(nil); await controller.refresh()
        reads = await service.reads; XCTAssertEqual(reads.count, 3)
        await controller.retry(); XCTAssertEqual(controller.status, .available)
        await controller.shutdown()
    }

    func testTransportFailureIsThrownAndPublished() async throws {
        let service = Service()
        let active = SystemMediaController(service: service, pollInterval: 3600)
        active.configure(source: .music); active.setPlaying(UUID(), true); await active.settled()
        try await active.perform(.pause)
        let commands = await service.controls; XCTAssertEqual(commands, [.pause])
        await service.setFailure(.appleEvent(code: -50, message: "Rejected"))
        do { try await active.perform(.skipNext); XCTFail("Expected action failure") }
        catch { XCTAssertEqual(error as? SystemMediaError, .appleEvent(code: -50, message: "Rejected")) }
        XCTAssertEqual(active.status, .failed); XCTAssertNil(active.snapshot)
        await active.shutdown()
    }

    func testShutdownWaitsForPendingReadAndRejectsNewWorkThenCanResumeRejectedQuit() async throws {
        let service = Service()
        let active = SystemMediaController(service: service, pollInterval: 3600)
        await service.holdNext(); active.configure(source: .music); active.setPlaying(UUID(), true)
        try await waitUntil { await service.isPending() }
        let shutdown = Task { await active.shutdown() }
        await Task.yield()
        XCTAssertNil(active.snapshot)
        active.setPlaying(UUID(), true)
        await service.release(.noCurrentItem); await shutdown.value
        XCTAssertEqual(active.status, .disabled)
        active.cancelShutdown(); await active.settled()
        XCTAssertEqual(active.status, .waitingForPlayback)
        let reads = await service.reads; XCTAssertEqual(reads.count, 1)
        active.setPlaying(UUID(), true); await active.settled()
        XCTAssertEqual(active.status, .available)
        await active.shutdown()
    }

    func testQueuedControlDoesNotRunAfterPriorControlFailed() async throws {
        let service = Service(), id = UUID()
        let controller = SystemMediaController(service: service, pollInterval: 3600)
        controller.configure(source: .music); controller.setPlaying(id, true); await controller.settled()
        await service.holdNextControl()
        let first = Task { try await controller.perform(.pause) }
        try await waitUntil { await service.isControlPending() }
        let second = Task { try await controller.perform(.skipNext) }
        try await Task.sleep(for: .milliseconds(10))
        await service.setFailure(.appleEvent(code: -50, message: "Rejected"))
        await service.releaseControl()
        do { try await first.value; XCTFail("Expected first failure") }
        catch { XCTAssertEqual(error as? SystemMediaError, .appleEvent(code: -50, message: "Rejected")) }
        do { try await second.value; XCTFail("Expected queued control rejection") }
        catch { XCTAssertEqual(error as? SystemMediaError, .noCurrentItem) }
        let controls = await service.controls
        XCTAssertEqual(controls, [.pause], "A queued control must recheck blocked state before dispatch")
        await controller.shutdown()
    }

    func testSourceChangeCancelsQueuedControlBeforeNativeDispatch() async throws {
        let service = Service()
        let controller = SystemMediaController(service: service, pollInterval: 3600)
        controller.configure(source: .music); controller.setPlaying(UUID(), true); await controller.settled()
        await service.holdNext()
        let refresh = Task { await controller.refresh() }
        try await waitUntil { await service.isPending() }
        let control = Task { try await controller.perform(.skipNext) }
        try await Task.sleep(for: .milliseconds(10))
        controller.configure(source: .spotify)
        await service.release(.noCurrentItem)
        await refresh.value
        do { try await control.value; XCTFail("Expected obsolete command cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await controller.settled()
        let controls = await service.controls; XCTAssertTrue(controls.isEmpty)
        XCTAssertEqual(controller.snapshot?.source, .spotify)
        await controller.shutdown()
    }

    func testTimerDoesNotRetainControllerAfterLastOwnerReleasesIt() async throws {
        let service = Service()
        var controller: SystemMediaController? = SystemMediaController(service: service, pollInterval: 0.01)
        let released = WeakController(controller)
        controller?.configure(source: .music); controller?.setPlaying(UUID(), true)
        await controller?.settled()
        controller = nil
        try await waitUntil { released.value == nil }
        let before = await service.reads.count
        try await Task.sleep(for: .milliseconds(30))
        let after = await service.reads.count
        XCTAssertEqual(after, before)
    }

    func testRejectedQuitCannotResumeUntilDispatchedWorkFinished() async throws {
        let service = Service()
        let controller = SystemMediaController(service: service, pollInterval: 3600)
        controller.configure(source: .music); controller.setPlaying(UUID(), true); await controller.settled()
        await service.holdNext()
        let refresh = Task { await controller.refresh() }
        try await waitUntil { await service.isPending() }
        var cleared = false
        controller.onSnapshot = { if $0 == nil { cleared = true } }
        let first = Task { await controller.shutdown() }
        try await waitUntil { cleared }
        let second = Task { await controller.shutdown() }
        controller.cancelShutdown()
        XCTAssertEqual(controller.status, .disabled, "Pending shutdown must not revive the controller")
        await service.release(.noCurrentItem)
        await refresh.value; await first.value; await second.value
        controller.cancelShutdown()
        XCTAssertEqual(controller.status, .waitingForPlayback)
        controller.setPlaying(UUID(), true); await controller.settled()
        XCTAssertEqual(controller.status, .available)
        await controller.shutdown()
    }

    func testRepeatedExplicitAuthorizationDoesNotQueueAnotherPrompt() async throws {
        let service = Service()
        let controller = SystemMediaController(service: service, pollInterval: 3600)
        await controller.authorize()
        let disabled = await service.reads; XCTAssertTrue(disabled.isEmpty)
        controller.configure(source: .music)
        await service.holdNext()
        let first = Task { await controller.authorize() }
        try await waitUntil { await service.isPending() }
        await controller.authorize()
        let pending = await service.reads; XCTAssertEqual(pending.count, 1); XCTAssertTrue(pending[0].1)
        await service.release(.noCurrentItem); await first.value
        await controller.shutdown()
    }

    func testSceneAuthorizationIsRecheckedInsideQueuedNativeDispatch() async throws {
        let service = Service(), controller = SystemMediaController(service: service, pollInterval: 3600)
        controller.configure(source: .music); controller.setPlaying(UUID(), true); await controller.settled()
        await service.holdNext()
        let refresh = Task { await controller.refresh() }
        try await waitUntil { await service.isPending() }
        var current = true, checks = 0
        let control = Task {
            try await controller.perform(.skipNext, whileCurrent: { checks += 1; return current })
        }
        try await waitUntil { checks == 1 }
        current = false
        await service.release(.noCurrentItem); await refresh.value
        do { try await control.value; XCTFail("Expected scene invalidation before OS dispatch") }
        catch { XCTAssertTrue(error is CancellationError) }
        let commands = await service.controls; XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(checks, 2)
        await controller.shutdown()
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for owned test operation"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
