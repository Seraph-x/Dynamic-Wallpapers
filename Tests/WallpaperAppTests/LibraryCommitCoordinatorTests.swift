import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class LibraryCommitCoordinatorTests: XCTestCase {
    private struct Failure: Error {}

    func testSaveFailurePublishesNothing() {
        var events: [String] = []
        let coordinator = LibraryCommitCoordinator(
            save: { _ in events.append("save"); throw Failure() },
            validateRemoval: { _ in events.append("validate") },
            withCommitLock: { operation in
                events.append("lock-enter"); defer { events.append("lock-exit") }
                try operation()
            })

        XCTAssertThrowsError(try coordinator.commit(current: .empty, change: {
            $0.settings.isMuted.toggle()
        }, beginRelease: { _ in events.append("release"); return Task {} },
        publish: { _ in events.append("publish") },
        screenSaverDidCommit: { _, _ in events.append("screen-saver") }))
        XCTAssertEqual(events, ["validate", "lock-enter", "save", "lock-exit"])
    }

    func testNoRemovalUsesExactLockedCommitOrder() throws {
        var events: [String] = []
        let coordinator = LibraryCommitCoordinator(save: { _ in events.append("save") },
            validateRemoval: { _ in events.append("validate") },
            withCommitLock: { operation in
                events.append("lock-enter"); defer { events.append("lock-exit") }
                try operation()
            })
        let result = try coordinator.commit(current: .empty, change: {
            $0.settings.isMuted.toggle()
        }, beginRelease: { _ in events.append("release"); return Task {} },
        publish: { _ in events.append("publish") },
        screenSaverDidCommit: { _, _ in events.append("screen-saver") })

        XCTAssertNil(result.releasing)
        XCTAssertEqual(events, ["validate", "lock-enter", "save", "publish", "screen-saver", "lock-exit"])
    }

    func testManagedRemovalQueuesDeletionBeforeSaveAndBeginsReleaseInsideLock() throws {
        var events: [String] = []
        var saved: Library?
        let item = MediaItem(url: URL(fileURLWithPath: "/managed/item.png"), kind: .image,
                             width: 2, height: 2,
                             origin: MediaOrigin(url: URL(fileURLWithPath: "/original/item.png")))
        var current = Library.empty
        current.media = [item]
        let coordinator = LibraryCommitCoordinator(
            save: { candidate in events.append("save"); saved = candidate },
            validateRemoval: { _ in events.append("validate") },
            withCommitLock: { operation in
                events.append("lock-enter"); defer { events.append("lock-exit") }
                try operation()
            })
        let result = try coordinator.commit(current: current, change: { $0.media = [] },
            beginRelease: { ids in
                XCTAssertEqual(ids, [item.id]); events.append("release"); return Task {}
            }, publish: { _ in events.append("publish") },
            screenSaverDidCommit: { _, _ in events.append("screen-saver") })

        XCTAssertEqual(saved?.pendingMediaDeletions, [item])
        XCTAssertEqual(result.removed, [item])
        XCTAssertNotNil(result.releasing)
        XCTAssertEqual(events, ["validate", "lock-enter", "save", "release", "publish", "screen-saver", "lock-exit"])
    }

    func testValidationFailurePerformsNoCommitEffects() {
        var events: [String] = []
        let item = MediaItem(url: URL(fileURLWithPath: "/external/item.png"), kind: .image,
                             width: 2, height: 2)
        var current = Library.empty
        current.media = [item]
        let coordinator = LibraryCommitCoordinator(save: { _ in events.append("save") },
            validateRemoval: { _ in events.append("validate"); throw Failure() },
            withCommitLock: { operation in events.append("lock"); try operation() })

        XCTAssertThrowsError(try coordinator.commit(current: current, change: { $0.media = [] },
            beginRelease: { _ in events.append("release"); return Task {} },
            publish: { _ in events.append("publish") },
            screenSaverDidCommit: { _, _ in events.append("screen-saver") }))
        XCTAssertEqual(events, ["validate"])
    }

}
