@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class PreviewLifecycleTests: XCTestCase {
    func testPreviewSurfaceFillsTheActualInspectorHostInsteadOfKeepingItsFactoryFrame() async throws {
        let factory = PreviewTestFactory()
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        let coordinator = LivePreview.Coordinator(lifetime: lifetime, onError: { XCTFail($0.localizedDescription) })
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 180, height: 112.5))
        let item = MediaItem(url: URL(fileURLWithPath: "/preview.png"), kind: .image, width: 32, height: 32)

        coordinator.start(item: item, host: host)
        await coordinator.task?.value

        let surface = try XCTUnwrap(factory.surfaces.first?.value)
        XCTAssertTrue(surface.view.superview === host)
        XCTAssertEqual(surface.view.frame, host.bounds)
        host.setFrameSize(CGSize(width: 240, height: 150))
        XCTAssertEqual(surface.view.frame, host.bounds)
        try await lifetime.closeAll()
    }

    func testFailedPreviewCloseRetainsBackendAfterViewOwnerIsReleased() async throws {
        let factory = PreviewTestFactory()
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        var errors: [String] = []
        var coordinator: LivePreview.Coordinator? = LivePreview.Coordinator(
            lifetime: lifetime, onError: { errors.append($0.localizedDescription) })
        start(try XCTUnwrap(coordinator))
        await coordinator?.task?.value
        let retainedSurface = try XCTUnwrap(factory.surfaces.first)
        retainedSurface.value?.closeError = WallpaperError("preview close failed")
        coordinator?.close()
        let closeTask = try XCTUnwrap(coordinator?.closeTask)
        coordinator = nil

        do { try await closeTask.value; XCTFail("Failed release must throw") }
        catch { XCTAssertEqual(error.localizedDescription, "preview close failed") }

        XCTAssertEqual(errors, ["preview close failed"])
        XCTAssertNotNil(retainedSurface.value, "The application owner must outlive the SwiftUI coordinator")
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        do { try await lifetime.waitForClosing(); XCTFail("Failed release must remain observable") }
        catch { XCTAssertEqual(error.localizedDescription, "preview close failed") }
    }

    func testReplacementWaitsForThePreviousPreviewToClose() async throws {
        let factory = PreviewTestFactory()
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        let first = LivePreview.Coordinator(lifetime: lifetime, onError: { XCTFail($0.localizedDescription) })
        start(first)
        await first.task?.value
        let outgoing = try XCTUnwrap(factory.surfaces.first?.value)
        outgoing.holdClose = true
        defer { outgoing.finishClose() }

        let second = LivePreview.Coordinator(lifetime: lifetime, onError: { XCTFail($0.localizedDescription) })
        start(second)
        await fulfillment(of: [outgoing.closeStarted], timeout: 1)
        XCTAssertTrue(outgoing.suppressed, "Replacement must gate old audio synchronously")
        XCTAssertEqual(factory.surfaces.count, 1)
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        XCTAssertNil(second.surface, "The new preview cannot bypass the occupied slot")

        outgoing.finishClose()
        await second.task?.value
        XCTAssertEqual(factory.surfaces.count, 2)
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        XCTAssertTrue(try XCTUnwrap(factory.surfaces.last?.value).playing)
        try await lifetime.closeAll()
    }

    func testFailedPreviousCloseBlocksEveryReplacement() async throws {
        let factory = PreviewTestFactory()
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        var errors: [String] = []
        let report: (Error) -> Void = { errors.append($0.localizedDescription) }
        let first = LivePreview.Coordinator(lifetime: lifetime, onError: report)
        start(first)
        await first.task?.value
        let outgoing = try XCTUnwrap(factory.surfaces.first?.value)
        outgoing.closeError = WallpaperError("old preview still active")

        let second = LivePreview.Coordinator(lifetime: lifetime, onError: report)
        start(second)
        await second.task?.value
        let third = LivePreview.Coordinator(lifetime: lifetime, onError: report)
        start(third)
        await third.task?.value

        XCTAssertEqual(factory.surfaces.count, 1)
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        XCTAssertNil(second.surface)
        XCTAssertNil(third.surface)
        XCTAssertTrue(errors.contains("old preview still active"))
        do { try await lifetime.closeAll(); XCTFail("Shutdown cannot claim failed resources were released") }
        catch { XCTAssertEqual(error.localizedDescription, "old preview still active") }
    }

    func testLateOldCoordinatorCannotCloseOrReportAgainstNewPreview() async throws {
        let factory = PreviewTestFactory()
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        var errors: [String] = []
        let report: (Error) -> Void = { errors.append($0.localizedDescription) }
        let first = LivePreview.Coordinator(lifetime: lifetime, onError: report)
        start(first)
        await first.task?.value
        let lateError = try XCTUnwrap(factory.surfaces.first?.value).onError
        let second = LivePreview.Coordinator(lifetime: lifetime, onError: report)
        start(second)
        await second.task?.value
        let current = try XCTUnwrap(factory.surfaces.last?.value)

        lateError?(WallpaperError("obsolete callback"))
        first.close()
        try await first.closeTask?.value
        XCTAssertTrue(errors.isEmpty)
        XCTAssertTrue(current.playing)
        XCTAssertTrue(second.surface === current)
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        try await lifetime.closeAll()
    }

    func testCancellingPreparationWaitsForActualClose() async throws {
        let factory = PreviewTestFactory()
        factory.configure = { $0.holdPrepare = true; $0.holdClose = true }
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        let coordinator = LivePreview.Coordinator(lifetime: lifetime, onError: { XCTFail($0.localizedDescription) })
        start(coordinator)
        let surface = try await waitForSurface(factory)
        defer { surface.finishPrepare(); surface.finishClose() }
        await fulfillment(of: [surface.prepareStarted], timeout: 1)
        coordinator.close()
        XCTAssertTrue(surface.suppressed)
        await fulfillment(of: [surface.closeStarted], timeout: 1)
        var preparationReturned = false
        let preparing = Task { await coordinator.task?.value; preparationReturned = true }

        surface.finishPrepare()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(preparationReturned, "Cancelled prepare must not finish before its close barrier")
        XCTAssertFalse(surface.playing)
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        surface.finishClose()
        await preparing.value
        try await coordinator.closeTask?.value
        XCTAssertTrue(preparationReturned)
        XCTAssertEqual(lifetime.activeSurfaceCount, 0)
    }

    func testCloseAllDrainsAndPermanentlyRejectsNewPreviews() async throws {
        let factory = PreviewTestFactory()
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        var errors: [String] = []
        let report: (Error) -> Void = { errors.append($0.localizedDescription) }
        let first = LivePreview.Coordinator(lifetime: lifetime, onError: report)
        start(first)
        await first.task?.value
        let outgoing = try XCTUnwrap(factory.surfaces.first?.value)
        outgoing.holdClose = true
        defer { outgoing.finishClose() }
        let second = LivePreview.Coordinator(lifetime: lifetime, onError: report)
        start(second)
        await fulfillment(of: [outgoing.closeStarted], timeout: 1)
        var shutdownFinished = false
        let shutdown = Task { try await lifetime.closeAll(); shutdownFinished = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(shutdownFinished)
        XCTAssertTrue(outgoing.suppressed)

        outgoing.finishClose()
        try await shutdown.value
        await second.task?.value
        XCTAssertEqual(factory.surfaces.count, 1, "Shutdown must cancel the replacement waiting for release")
        XCTAssertEqual(lifetime.activeSurfaceCount, 0)
        let afterShutdown = LivePreview.Coordinator(lifetime: lifetime, onError: report)
        start(afterShutdown)
        await afterShutdown.task?.value
        XCTAssertEqual(factory.surfaces.count, 1)
        XCTAssertTrue(errors.contains { $0.contains("已关闭") })
    }

    func testCloseFailureIsReturnedWithoutClaimingInFlightPreparationStopped() async throws {
        let factory = PreviewTestFactory()
        factory.configure = { $0.holdPrepare = true; $0.closeError = WallpaperError("cannot close preparing preview") }
        let lifetime = PreviewLifetime(surfaceFactory: factory)
        var errors: [String] = []
        let coordinator = LivePreview.Coordinator(lifetime: lifetime, onError: { errors.append($0.localizedDescription) })
        start(coordinator)
        let surface = try await waitForSurface(factory)
        defer { surface.finishPrepare() }
        await fulfillment(of: [surface.prepareStarted], timeout: 1)
        do { try await lifetime.closeAll(); XCTFail("Failed close must throw, not wait indefinitely or report success") }
        catch { XCTAssertEqual(error.localizedDescription, "cannot close preparing preview") }
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
        XCTAssertTrue(surface.suppressed)
        XCTAssertEqual(errors, ["cannot close preparing preview"])
        surface.finishPrepare()
        await coordinator.task?.value
        XCTAssertFalse(surface.playing)
        XCTAssertEqual(lifetime.activeSurfaceCount, 1)
    }

    private func start(_ coordinator: LivePreview.Coordinator) {
        let item = MediaItem(url: URL(fileURLWithPath: "/preview.png"), kind: .image, width: 32, height: 32)
        coordinator.start(item: item, host: NSView(frame: CGRect(x: 0, y: 0, width: 32, height: 32)))
    }

    private func waitForSurface(_ factory: PreviewTestFactory) async throws -> ControlledSurface {
        let deadline = ContinuousClock.now + .seconds(1)
        while factory.surfaces.isEmpty {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Preview allocation timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
        return try XCTUnwrap(factory.surfaces.first?.value)
    }
}

@MainActor
private final class PreviewTestFactory: SurfaceMaking {
    final class Reference {
        weak var value: ControlledSurface?
        init(_ value: ControlledSurface) { self.value = value }
    }
    private(set) var surfaces: [Reference] = []
    var configure: (ControlledSurface) -> Void = { _ in }

    func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
        let surface = ControlledSurface()
        configure(surface)
        surfaces.append(Reference(surface))
        return surface
    }
}
