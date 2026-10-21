@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class UnifiedPreviewLifecycleTests: XCTestCase {
    func testPowerPausedLifetimeRejectsStartWithoutAllocatingAndAllowsWake() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        let lifetime = makeLifetime(fixture)
        lifetime.setPowerPaused(true)
        var stopped = false
        var errors: [String] = []
        do {
            _ = try await lifetime.prepare(request(fixture), configure: { _ in },
                onError: { errors.append($0.localizedDescription) }, onStop: { stopped = true })
            XCTFail("Existing power pause must prevent preview allocation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("暂停")) }
        try await fixture.wait { stopped }
        XCTAssertTrue(fixture.factory.records.isEmpty)
        XCTAssertEqual(errors.count, 1)
        lifetime.setPowerPaused(false)
        let next = request(fixture)
        _ = try await prepare(next, lifetime: lifetime)
        try await lifetime.play(next.id)
        XCTAssertEqual(lifetime.activeDesktopSurfaceCount, 1)
        try await lifetime.closeAll()
    }

    func testClosedPreviewReleasesItsUIStopHandler() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        let lifetime = makeLifetime(fixture)
        var owner: StopHandlerOwner? = StopHandlerOwner()
        let released = StopHandlerReference(owner)
        _ = try await lifetime.prepare(request(fixture), configure: { _ in }, onError: { XCTFail($0.localizedDescription) },
            onStop: try XCTUnwrap(owner).handler())
        owner = nil
        XCTAssertNotNil(released.value)
        try await lifetime.closeAll()
        XCTAssertNil(released.value, "The application-owned lifetime must not retain a dismantled SwiftUI view through onStop")
    }

    func testUnifiedStartUsesInspectorAudioAndSilencesEveryDesktopCopy() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let lifetime = makeLifetime(fixture)
        let request = request(fixture)
        let inline = try await prepare(request, lifetime: lifetime)
        XCTAssertFalse((inline as? ControlledSurface)?.playing ?? true)
        try await lifetime.play(request.id)
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        XCTAssertEqual(lifetime.activeDesktopSurfaceCount, 1)
        let inlineSurface = try XCTUnwrap(inline as? ControlledSurface)
        let desktop = fixture.factory.records[2].surface
        XCTAssertTrue(inlineSurface.playing)
        XCTAssertFalse(inlineSurface.globallyMuted)
        XCTAssertEqual(inlineSurface.audio.volume, 0.4)
        XCTAssertTrue(desktop.playing && desktop.globallyMuted)
        inline.setGlobalMute(true)
        XCTAssertTrue(inlineSurface.globallyMuted && desktop.globallyMuted)
        try await lifetime.closeAll()
        try await fixture.wait { fixture.factory.records[0].surface.playing }
        XCTAssertEqual(lifetime.activeDesktopSurfaceCount, 0)
    }

    func testInlineRuntimeFailureEndsBothPreviewsAndRestoresDesktop() async throws {
        try await verifyRuntimeFailure(surfaceIndex: 1)
    }

    func testDesktopRuntimeFailureEndsBothPreviewsAndRestoresDesktop() async throws {
        try await verifyRuntimeFailure(surfaceIndex: 2)
    }

    func testCancellingDesktopPreparationCannotPlayEitherSurface() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let lifetime = makeLifetime(fixture)
        fixture.factory.configure = { surface in
            surface.holdPrepare = fixture.factory.records.count == 2
        }
        let request = request(fixture)
        let preparing = Task { try await self.prepare(request, lifetime: lifetime) }
        try await fixture.wait { fixture.factory.records.count == 3 }
        let desktop = fixture.factory.records[2].surface
        await fulfillment(of: [desktop.prepareStarted], timeout: 1)
        let closing = lifetime.cancel(request.id)
        XCTAssertTrue(fixture.factory.records[1].surface.suppressed)
        desktop.finishPrepare()
        do { _ = try await preparing.value; XCTFail("Cancelled preparation cannot succeed") }
        catch is CancellationError { }
        try await closing?.value
        XCTAssertFalse(fixture.factory.records[1].surface.playing)
        XCTAssertFalse(desktop.playing)
        XCTAssertTrue(fixture.factory.records[0].surface.playing)
        XCTAssertEqual(lifetime.activeSurfaceCount, 0)
        try await lifetime.closeAll()
    }

    func testReplacementWaitsForBothClosesAndRejectsOldCallbacks() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let lifetime = makeLifetime(fixture)
        let first = request(fixture)
        _ = try await prepare(first, lifetime: lifetime)
        try await lifetime.play(first.id)
        let outgoing = fixture.factory.records[2].surface
        let lateFailure = outgoing.onError
        outgoing.holdClose = true
        defer { outgoing.finishClose() }
        let second = request(fixture)
        let replacement = Task { try await self.prepare(second, lifetime: lifetime) }
        await fulfillment(of: [outgoing.closeStarted], timeout: 1)
        XCTAssertEqual(fixture.factory.records.count, 3, "A closing desktop resource still occupies the preview slot")
        outgoing.finishClose()
        _ = try await replacement.value
        try await lifetime.play(second.id)
        lateFailure?(WallpaperError("obsolete desktop error"))
        _ = lifetime.cancel(first.id)
        XCTAssertTrue(lifetime.isCurrent(second.id))
        XCTAssertTrue(fixture.factory.records.last?.surface.playing == true)
        try await lifetime.closeAll()
    }

    func testDesktopCloseFailureRetainsUnifiedSlotAndBlocksNewAllocations() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let lifetime = makeLifetime(fixture)
        var errors: [String] = []
        let report: (Error) -> Void = { errors.append($0.localizedDescription) }
        let first = request(fixture)
        _ = try await lifetime.prepare(first, configure: { _ in }, onError: report)
        try await lifetime.play(first.id)
        fixture.factory.records[2].surface.closeError = WallpaperError("desktop cannot close")
        do { try await lifetime.cancel(first.id)?.value; XCTFail("Close must throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("desktop cannot close")) }
        let next = request(fixture)
        do { _ = try await lifetime.prepare(next, configure: { _ in }, onError: report); XCTFail("Replacement must throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("desktop cannot close")) }
        XCTAssertEqual(fixture.factory.records.count, 3)
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        XCTAssertEqual(lifetime.activeDesktopSurfaceCount, 1)
        XCTAssertTrue(errors.contains { $0.contains("desktop cannot close") })
        do { try await lifetime.closeAll(); XCTFail("Shutdown must throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("desktop cannot close")) }
    }

    func testRequestedDesktopPreviewWithoutControllerIsAnExplicitFailure() async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        let lifetime = PreviewLifetime(surfaceFactory: fixture.factory)
        var errors: [String] = []
        do {
            _ = try await lifetime.prepare(request(fixture), configure: { _ in },
                onError: { errors.append($0.localizedDescription) })
            XCTFail("A desktop request must not silently degrade into inline-only playback")
        } catch { XCTAssertTrue(error.localizedDescription.contains("桌面预览")) }
        XCTAssertFalse(errors.isEmpty)
        try await lifetime.closeAll()
    }

    private func verifyRuntimeFailure(surfaceIndex: Int) async throws {
        let fixture = try DesktopPreviewFixture()
        defer { fixture.close() }
        try await fixture.displayOriginal()
        let lifetime = makeLifetime(fixture)
        var errors: [String] = []
        var stopped = false
        let request = request(fixture)
        _ = try await lifetime.prepare(request, configure: { _ in },
            onError: { errors.append($0.localizedDescription) }, onStop: { stopped = true })
        try await lifetime.play(request.id)
        fixture.factory.records[surfaceIndex].surface.onError?(WallpaperError("preview runtime failed"))
        try await lifetime.waitForClosing()
        try await fixture.wait { fixture.factory.records[0].surface.playing && stopped }
        XCTAssertEqual(errors, ["preview runtime failed"])
        XCTAssertEqual(lifetime.activeSurfaceCount, 0)
        XCTAssertEqual(lifetime.activeDesktopSurfaceCount, 0)
        try await lifetime.closeAll()
    }

    private func makeLifetime(_ fixture: DesktopPreviewFixture) -> PreviewLifetime {
        PreviewLifetime(surfaceFactory: fixture.factory, desktopPreviews: fixture.coordinator.previews)
    }

    private func request(_ fixture: DesktopPreviewFixture) -> PreviewLifetime.Request {
        PreviewLifetime.Request(id: UUID(), item: fixture.candidate, size: CGSize(width: 300, height: 188),
            scale: 2, fit: .fit, desktopTarget: DesktopPreviewTarget(displayID: "A", fit: .fill))
    }

    private func prepare(_ request: PreviewLifetime.Request, lifetime: PreviewLifetime) async throws -> any PlaybackSurface {
        try await lifetime.prepare(request, configure: {
            $0.setAudio(AudioSettings(volume: 0.4)); $0.setGlobalMute(false)
        }, onError: { XCTFail($0.localizedDescription) })
    }

    @MainActor private final class StopHandlerOwner {
        var called = false
        func handler() -> () -> Void { { self.called = true } }
    }

    @MainActor private final class StopHandlerReference {
        weak var value: StopHandlerOwner?
        init(_ value: StopHandlerOwner?) { self.value = value }
    }
}
