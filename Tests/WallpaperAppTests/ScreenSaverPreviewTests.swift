import AppKit
import ScreenSaverCore
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class ScreenSaverPreviewTests: XCTestCase {
    func testPreviewUsesPublishedGenerationAndReleasesItsOwnRuntime() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let model = ScreenSaverModel(publisher: try await fixture.makePublisher())
        model.attach(library: fixture.library, loaded: true)
        let published = try await model.update(fixture.settings).value
        let pointer = try XCTUnwrap(published)
        model.preview.view.frame = CGRect(x: 0, y: 0, width: 600, height: 300)

        try await model.preview.start(published: pointer, verified: model.state.currentVerified)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.preview.state?.phase != .playing {
            if let failure = model.preview.state?.failure { throw failure }
            guard ContinuousClock.now < deadline else { throw WallpaperError("屏保预览未显示首帧。") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.preview.state?.generationID, pointer.generationID)
        try await model.preview.stop().value
        XCTAssertEqual(model.preview.state?.phase, .stopped)
        XCTAssertTrue(model.preview.view.subviews.isEmpty)
        try await model.beginShutdown().value
    }

    func testPreviewRejectsUnverifiedPublicationWithoutStartingRuntime() async throws {
        let controller = ScreenSaverPreviewController(root: FileManager.default.temporaryDirectory)
        _ = try await screenSaverFailure { try await controller.start(published: nil, verified: false) }
        XCTAssertNil(controller.state)
        XCTAssertTrue(controller.view.subviews.isEmpty)
    }

    func testPresentationStartSurfacesFailureWithoutDiscardingAThrowingTask() async {
        let controller = ScreenSaverPreviewController(root: FileManager.default.temporaryDirectory)

        await controller.startForPresentation(published: nil, verified: false).value

        XCTAssertEqual(controller.failure?.code, .previewUnavailable)
        XCTAssertNil(controller.state)
    }

    func testManualPreviewRestartLoadsTheNewlyPublishedGeneration() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let model = ScreenSaverModel(publisher: try await fixture.makePublisher())
        model.attach(library: fixture.library, loaded: true)
        let firstResult = try await model.update(fixture.settings).value
        let first = try XCTUnwrap(firstResult)
        model.preview.view.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        try await model.preview.start(published: first, verified: true)
        try await waitForPreview(model.preview, generation: try XCTUnwrap(first.generationID))

        let secondResult = try await model.update(fixture.settings, force: true).value
        let second = try XCTUnwrap(secondResult)
        XCTAssertNotEqual(first.generationID, second.generationID)
        try await model.preview.start(published: second, verified: true)

        try await waitForPreview(model.preview, generation: try XCTUnwrap(second.generationID))
        try await model.beginShutdown().value
    }

    func testPublishingStopsPreviewBeforeReplacingAndCollectingItsGeneration() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let model = ScreenSaverModel(publisher: try await fixture.makePublisher())
        model.attach(library: fixture.library, loaded: true)
        let firstResult = try await model.update(fixture.settings).value
        let first = try XCTUnwrap(firstResult)
        model.preview.view.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        try await model.preview.start(published: first, verified: true)
        try await waitForPreview(model.preview, generation: try XCTUnwrap(first.generationID))

        let secondResult = try await model.update(fixture.settings, force: true).value
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(model.preview.state?.phase, .stopped)
        let generationNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.store.paths.generations.path
        ).filter { UUID(uuidString: $0)?.uuidString == $0 }
        XCTAssertEqual(generationNames, [try XCTUnwrap(second.generationID).uuidString])
        try await model.beginShutdown().value
    }

    private func waitForPreview(_ controller: ScreenSaverPreviewController, generation: UUID) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.state?.phase != .playing || controller.state?.generationID != generation {
            if let failure = controller.state?.failure { throw failure }
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("Screen saver preview did not load generation \(generation)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
