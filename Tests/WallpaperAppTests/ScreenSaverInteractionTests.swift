import ScreenSaverCore
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class ScreenSaverInteractionTests: XCTestCase {
    func testShutdownRejectsScreenSaverChangesWithLifecycleCode() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let screenSaver = ScreenSaverModel(publisher: try await fixture.makePublisher())
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        try await model.shutdownAndWait()

        let binding = await model.bindScreenSaver(.media(fixture.item.id)).result
        let clearing = await model.clearPublishedScreenSaver().result

        guard case .failure(let bindingError) = binding,
              case .failure(let clearingError) = clearing else {
            return XCTFail("Shutdown must reject both screen saver changes")
        }
        XCTAssertEqual((bindingError as? ScreenSaverFailure)?.code, .applicationClosing(.configuration))
        XCTAssertEqual((clearingError as? ScreenSaverFailure)?.code, .applicationClosing(.configuration))
    }

    func testBindingAnItemForScreenSaverDoesNotEditTheLibrary() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let screenSaver = ScreenSaverModel(publisher: try await fixture.makePublisher())
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        let original = try Data(contentsOf: store.url)

        _ = try await model.bindScreenSaver(.media(fixture.item.id)).value

        XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertEqual(model.library, fixture.library)
        XCTAssertEqual(model.section, .screenSaver)
        XCTAssertEqual(screenSaver.state.phase, .published)
        try await model.shutdownAndWait()
    }

    func testReviewingOldExclusionListCannotApproveANewlyExcludedItem() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        var library = fixture.library
        let excluded = MediaItem(url: fixture.item.url, kind: .video, width: 64, height: 64,
                                 duration: 1, backend: .extended)
        library.media.append(excluded)
        library.playlists[0].entries.append(PlaylistEntry(mediaID: excluded.id))
        let screenSaver = ScreenSaverModel(publisher: try await fixture.makePublisher())
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(library)
        let model = AppModel(store: store, screenSaver: screenSaver)

        let displayed = try ScreenSaverProjection(library: model.library, source: .playlist(library.playlists[0].id))
        XCTAssertEqual(displayed.exclusions.count, 1)
        let next = MediaItem(url: fixture.item.url, kind: .video, width: 64, height: 64,
                             duration: 1, backend: .extended)
        XCTAssertTrue(model.mutate {
            $0.media.append(next)
            $0.playlists[0].entries.append(PlaylistEntry(mediaID: next.id))
        })

        let result = await model.bindScreenSaver(displayed).result

        if case .success = result { XCTFail("A stale review published unseen content") }
        XCTAssertNil(screenSaver.settings.source)
        XCTAssertNil(screenSaver.state.published)
        XCTAssertEqual(model.library.playlists[0].entries.count, 4)
        try await model.shutdownAndWait()
    }

    func testReviewedExclusionsPublishWithoutEditingThePlaylist() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        var library = fixture.library
        let excluded = MediaItem(url: fixture.item.url, kind: .video, width: 64, height: 64,
                                 duration: 1, backend: .extended)
        library.media.append(excluded)
        library.playlists[0].entries.append(PlaylistEntry(mediaID: excluded.id))
        let screenSaver = ScreenSaverModel(publisher: try await fixture.makePublisher())
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("reviewed-library.json"))
        try store.save(library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        let before = try Data(contentsOf: store.url)
        let review = try ScreenSaverProjection(library: model.library, source: .playlist(library.playlists[0].id))

        _ = try await model.bindScreenSaver(review).value

        XCTAssertEqual(screenSaver.state.phase, .published)
        XCTAssertEqual(screenSaver.settings.consent?.signatures, review.exclusions.map(\.signature))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        try await model.shutdownAndWait()
    }

    func testMultipleScreenSaverImportsRequireAnExplicitChoiceAndDoNotAppendToSelectedPlaylist() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let screenSaver = ScreenSaverModel(publisher: try await fixture.makePublisher())
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        let playlistID = fixture.library.playlists[0].id
        model.section = .playlist(playlistID)
        let first = fixture.directory.appendingPathComponent("screen-one.png")
        let second = fixture.directory.appendingPathComponent("screen-two.png")
        try FileManager.default.copyItem(at: fixture.item.url, to: first)
        try FileManager.default.copyItem(at: fixture.item.url, to: second)

        model.importURLs([first, second], purpose: .screenSaver)
        try await waitForImport(model)

        XCTAssertEqual(model.section, .screenSaver)
        XCTAssertEqual(model.library.playlists[0].entries, fixture.library.playlists[0].entries)
        XCTAssertNil(screenSaver.settings.source)
        XCTAssertEqual(model.screenSaverImportChoices.count, 2)
        let selected = try XCTUnwrap(model.screenSaverImportChoices.last)
        let review = try ScreenSaverProjection(library: model.library, source: .media(selected))
        _ = try await model.bindScreenSaver(review).value
        model.discardScreenSaverImportChoices()
        XCTAssertEqual(screenSaver.settings.source, .media(selected))
        XCTAssertTrue(model.screenSaverImportChoices.isEmpty)
        try await model.shutdownAndWait()
    }

    func testSingleScreenSaverImportWaitsForExplicitReviewWithoutChangingPlaylist() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let screenSaver = ScreenSaverModel(publisher: try await fixture.makePublisher())
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        let imported = fixture.directory.appendingPathComponent("single-screen.png")
        try FileManager.default.copyItem(at: fixture.item.url, to: imported)

        model.importURLs([imported], purpose: .screenSaver)
        try await waitForImport(model)
        let newItem = try XCTUnwrap(model.library.media.first { $0.origin?.url == imported.standardizedFileURL })
        XCTAssertNil(screenSaver.settings.source)
        XCTAssertEqual(model.library.playlists[0].entries, fixture.library.playlists[0].entries)
        XCTAssertEqual(model.screenSaverImportChoices, [newItem.id])
        let review = try ScreenSaverProjection(library: model.library, source: .media(newItem.id))
        _ = try await model.bindScreenSaver(review).value
        model.discardScreenSaverImportChoices()
        XCTAssertEqual(screenSaver.settings.source, .media(newItem.id))
        XCTAssertTrue(model.screenSaverImportChoices.isEmpty)
        try await model.shutdownAndWait()
    }

    func testClearingPublishedScreenSaverDoesNotChangeTheLibrary() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let screenSaver = ScreenSaverModel(publisher: try await fixture.makePublisher())
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("app-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: screenSaver)
        _ = try await model.bindScreenSaver(.media(fixture.item.id)).value
        let original = try Data(contentsOf: store.url)

        _ = try await model.clearPublishedScreenSaver().value

        XCTAssertNil(screenSaver.settings.source)
        XCTAssertNil(screenSaver.state.published?.generationID)
        XCTAssertEqual(try Data(contentsOf: store.url), original)
        XCTAssertEqual(model.library, fixture.library)
        try await model.shutdownAndWait()
    }

    func testClearRemainsAvailableWhenIntentIsDisabledButOldPublicationIsStillActive() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let firstModel = ScreenSaverModel(publisher: try await fixture.makePublisher())
        firstModel.attach(library: fixture.library, loaded: true)
        _ = try await firstModel.update(fixture.settings).value
        let target = try XCTUnwrap(firstModel.state.target)
        try await firstModel.beginShutdown().value
        _ = try await fixture.makeSettingsStore().save(ScreenSaverSettings(), sourceRevision: nil,
                                                         replacing: target.revision)

        let reloaded = ScreenSaverModel(publisher: try await fixture.makePublisher())
        let store = LibraryStore(url: fixture.directory.appendingPathComponent("reloaded-library.json"))
        try store.save(fixture.library)
        let model = AppModel(store: store, screenSaver: reloaded)
        XCTAssertNil(reloaded.settings.source)
        XCTAssertNotNil(reloaded.state.published?.generationID)
        XCTAssertTrue(model.canClearPublishedScreenSaver)

        _ = try await model.clearPublishedScreenSaver().value

        XCTAssertNil(reloaded.state.published?.generationID)
        try await model.shutdownAndWait()
    }

    func testPublishedStatusRequiresVerifiedCurrentContent() async throws {
        let fixture = try await ScreenSaverPublishFixture.make(in: self)
        let screenSaver = ScreenSaverModel(publisher: try await fixture.makePublisher())
        screenSaver.attach(library: fixture.library, loaded: true)
        _ = try await screenSaver.update(fixture.settings).value

        XCTAssertTrue(screenSaver.state.currentVerified)
        XCTAssertNotNil(screenSaver.state.published?.generationID)
        try await screenSaver.beginShutdown().value
    }

    private func waitForImport(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.importing {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Screen saver import did not complete") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
