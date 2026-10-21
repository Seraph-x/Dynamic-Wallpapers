@testable import WallpaperNative
import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class CoordinatorRetirementTests: XCTestCase {
    func testRetiringScreenDoesNotPreventAnotherScreenFromUnbinding() async throws {
        let fixture = try Fixture()
        defer { fixture.factory.surfaces.values.forEach { $0.finishClose() }; fixture.coordinator.shutdown() }
        let committed = expectation(description: "both screens display")
        committed.expectedFulfillmentCount = 2
        fixture.coordinator.onCommit = { _, _ in committed.fulfill() }
        fixture.coordinator.onError = { XCTFail($0.localizedDescription) }
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [committed], timeout: 1)
        let a = try XCTUnwrap(fixture.factory.surfaces[fixture.items[0].id])
        let b = try XCTUnwrap(fixture.factory.surfaces[fixture.items[1].id])
        a.holdClose = true
        var unbound = fixture.library
        unbound.displays.removeAll { $0.id == "A" }
        fixture.coordinator.reconcile(unbound)
        await fulfillment(of: [a.closeStarted], timeout: 1)
        unbound.displays.removeAll()
        fixture.coordinator.reconcile(unbound)
        XCTAssertTrue(b.suppressed, "Unbinding B must synchronously silence B even while A is closing")
        await fulfillment(of: [b.closeStarted], timeout: 1)
        a.finishClose()
    }

    func testFailedRetirementDoesNotPreventHealthyScreenFromUnbinding() async throws {
        let fixture = try Fixture()
        defer { fixture.coordinator.shutdown() }
        let committed = expectation(description: "both screens display")
        committed.expectedFulfillmentCount = 2
        fixture.coordinator.onCommit = { _, _ in committed.fulfill() }
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [committed], timeout: 1)
        let a = try XCTUnwrap(fixture.factory.surfaces[fixture.items[0].id])
        let b = try XCTUnwrap(fixture.factory.surfaces[fixture.items[1].id])
        a.closeError = WallpaperError("A release failed")
        let error = expectation(description: "retirement failure is visible")
        error.assertForOverFulfill = false
        fixture.coordinator.onError = { value in
            XCTAssertEqual(value.localizedDescription, "A release failed")
            error.fulfill()
        }
        var unbound = fixture.library
        unbound.displays.removeAll { $0.id == "A" }
        fixture.coordinator.reconcile(unbound)
        await fulfillment(of: [error], timeout: 1)
        unbound.displays.removeAll()
        fixture.coordinator.reconcile(unbound)
        XCTAssertTrue(b.suppressed)
        await fulfillment(of: [b.closeStarted], timeout: 1)
        XCTAssertEqual(a.state, .failed, "The failed resource remains owned, not marked released")
    }

    func testUnrelatedNewScreenCanStartWhileAnotherScreenRetires() async throws {
        let fixture = try Fixture()
        defer { fixture.factory.surfaces.values.forEach { $0.finishClose() }; fixture.coordinator.shutdown() }
        var library = fixture.library
        library.displays.removeAll { $0.id == "B" }
        let first = expectation(description: "A displayed")
        fixture.coordinator.onCommit = { _, _ in first.fulfill() }
        fixture.coordinator.onError = { XCTFail($0.localizedDescription) }
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [first], timeout: 1)
        let a = try XCTUnwrap(fixture.factory.surfaces[fixture.items[0].id])
        a.holdClose = true
        library.displays = []
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [a.closeStarted], timeout: 1)
        let second = expectation(description: "B displayed independently")
        fixture.coordinator.onCommit = { _, _ in second.fulfill() }
        library.displays = [fixture.library.displays[1]]
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [second], timeout: 1)
        XCTAssertNotNil(fixture.factory.surfaces[fixture.items[1].id])
        a.finishClose()
    }

    func testUnbindingHealthyScreenIsImmediateWhileAnotherTransitionWaitsForClose() async throws {
        let fixture = try Fixture()
        defer { fixture.factory.surfaces.values.forEach { $0.finishClose() }; fixture.coordinator.shutdown() }
        var library = fixture.library
        library.playlists[0].entries.append(PlaylistEntry(mediaID: fixture.items[1].id))
        let initial = expectation(description: "both original frames displayed")
        initial.expectedFulfillmentCount = 2
        fixture.coordinator.onCommit = { _, _ in initial.fulfill() }
        fixture.coordinator.onError = { XCTFail($0.localizedDescription) }
        fixture.coordinator.reconcile(library)
        await fulfillment(of: [initial], timeout: 1)
        fixture.coordinator.onCommit = { _, _ in }
        let outgoingA = try XCTUnwrap(fixture.factory.surfaces[fixture.items[0].id])
        let b = try XCTUnwrap(fixture.factory.surfaces[fixture.items[1].id])
        outgoingA.holdClose = true
        defer { outgoingA.finishClose() }
        fixture.coordinator.next(groupID: library.displays[0].groupID)
        await fulfillment(of: [outgoingA.closeStarted], timeout: 1)

        library.displays.removeAll { $0.id == "B" }
        fixture.coordinator.reconcile(library)
        XCTAssertTrue(b.suppressed, "A transition's asynchronous close cannot defer B's stop request")
        await fulfillment(of: [b.closeStarted], timeout: 1)
        outgoingA.finishClose()
    }

    func testShutdownRejectsLateReconcileBeforeAndAfterClosingCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.factory.surfaces.values.forEach { $0.finishClose() }; fixture.coordinator.shutdown() }
        let initial = expectation(description: "both original frames displayed")
        initial.expectedFulfillmentCount = 2
        fixture.coordinator.onCommit = { _, _ in initial.fulfill() }
        fixture.coordinator.onError = { XCTFail($0.localizedDescription) }
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [initial], timeout: 1)
        let surfaces = Array(fixture.factory.surfaces.values)
        surfaces.forEach { $0.holdClose = true }
        let unexpected = expectation(description: "shutdown must not create another frame")
        unexpected.isInverted = true
        // Both screens can expose the bug; keep the inverted failure without an over-fulfill exception.
        unexpected.assertForOverFulfill = false
        fixture.coordinator.onCommit = { _, _ in unexpected.fulfill() }
        fixture.coordinator.shutdown()
        await fulfillment(of: surfaces.map(\.closeStarted), timeout: 1)
        fixture.coordinator.reconcile(fixture.library) // A previously queued screen notification.
        surfaces.forEach { $0.finishClose() }
        try await fixture.coordinator.waitForShutdown()
        fixture.coordinator.reconcile(fixture.library)
        await fulfillment(of: [unexpected], timeout: 0.15)
        XCTAssertEqual(fixture.factory.creationCount, 2)
    }

    @MainActor private struct Fixture {
        let factory = RecordingFactory()
        let coordinator: DesktopCoordinator
        let items: [MediaItem]
        let library: Library
        init() throws {
            _ = NSApplication.shared
            let screen = try XCTUnwrap(NSScreen.main)
            coordinator = DesktopCoordinator(surfaceFactory: factory, screenProvider: { ["A": screen, "B": screen] })
            items = ["A", "B"].map { MediaItem(url: URL(fileURLWithPath: "/\($0).png"), kind: .image, width: 32, height: 32) }
            var library = Library.empty
            library.media = items
            library.playlists = items.map { Playlist(name: $0.name, entries: [PlaylistEntry(mediaID: $0.id)], transition: 0) }
            library.displays = zip(["A", "B"], library.playlists).map { DisplayBinding(id: $0, playlistID: $1.id) }
            self.library = library
        }
    }

    private final class RecordingFactory: SurfaceMaking {
        var surfaces: [UUID: ControlledSurface] = [:]
        var creationCount = 0
        func makeSurface(item: MediaItem, size: CGSize, fit: ContentFit) throws -> any PlaybackSurface {
            creationCount += 1
            let surface = ControlledSurface()
            surfaces[item.id] = surface
            return surface
        }
    }
}
