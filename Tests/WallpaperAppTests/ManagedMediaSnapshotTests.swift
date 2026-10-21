import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ManagedMediaSnapshotTests: XCTestCase {
    func testRemovalWaitsForTheInitialCaptureEvenAfterItsCallerCancels() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.gate.release(); fixture.coordinator.shutdown() }
        var library = Library.empty
        library.media = [fixture.item]
        library.displays = [DisplayBinding(id: fixture.displayID, source: .media(fixture.item.id, audio: AudioSettings()))]
        let displayed = expectation(description: "wallpaper displayed")
        fixture.coordinator.onCommit = { _, _ in displayed.fulfill() }
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [displayed], timeout: 2)
        let surface = try XCTUnwrap(fixture.factory.surfaces.first)
        let capture = Task { try await fixture.coordinator.captureWallpaper(on: fixture.screen) }
        try await WallpaperMirrorTestSupport.waitUntil(description: "initial capture started") { fixture.gate.started }
        capture.cancel()
        let removal = fixture.coordinator.beginRemovingMedia([fixture.item.id])
        library.media = []; library.displays = []
        fixture.coordinator.reconcile(library)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(surface.state, .closed)
        fixture.gate.release()
        do { _ = try await capture.value; XCTFail("The injected capture failure must reach its caller") }
        catch { XCTAssertTrue(error.localizedDescription.contains("snapshot finished")) }
        try await removal.value
        XCTAssertEqual(surface.state, .closed)
        fixture.coordinator.shutdown()
        try await fixture.coordinator.waitForShutdown()
    }

    func testPreviewReleaseWaitsForTheInitialCaptureWithoutAMirror() async throws {
        let fixture = try SnapshotFixture()
        defer { fixture.gate.release(); fixture.coordinator.shutdown() }
        let preview = try fixture.coordinator.previews.makeSession(id: UUID(), item: fixture.item,
            target: DesktopPreviewTarget(displayID: fixture.displayID, fit: .fill), onError: { XCTFail("\($0)") })
        try await preview.prepare()
        try await preview.start()
        let surface = try XCTUnwrap(fixture.factory.surfaces.first)
        let capture = Task { try await fixture.coordinator.captureWallpaper(on: fixture.screen) }
        try await WallpaperMirrorTestSupport.waitUntil(description: "preview capture started") { fixture.gate.started }
        let removal = preview.beginClose()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotEqual(surface.state, .closed)
        fixture.gate.release()
        do { _ = try await capture.value; XCTFail("The injected capture failure must reach its caller") }
        catch { XCTAssertTrue(error.localizedDescription.contains("snapshot finished")) }
        try await removal.value
        XCTAssertEqual(surface.state, .closed)
        fixture.coordinator.shutdown()
        try await fixture.coordinator.waitForShutdown()
    }
}

@MainActor
private final class SnapshotFixture {
    let screen: NSScreen
    let displayID: String
    let gate = ManagedReadGate()
    let factory = ControlledFactory()
    let coordinator: DesktopCoordinator
    let item = MediaItem(url: URL(fileURLWithPath: "/snapshot.png"), kind: .image, width: 32, height: 32)

    init() throws {
        screen = try XCTUnwrap(NSScreen.main)
        displayID = try XCTUnwrap(screen.wallpaperID)
        let screen = screen, displayID = displayID, gate = gate
        coordinator = DesktopCoordinator(surfaceFactory: factory, screenProvider: { [displayID: screen] },
            snapshotWindow: { _ in await gate.wait(); throw WallpaperError("snapshot finished with an error") })
    }
}
