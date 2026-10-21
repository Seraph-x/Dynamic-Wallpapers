import XCTest
import Darwin
import ScreenSaverCore

final class SnapshotLeaseTests: SnapshotTestCase {
    func testTwoSameProcessReadersHaveIndependentKernelLeases() async throws {
        let first = try await fixture.publish(in: store)
        let openedOne = try await store.acquireCurrent()
        let openedTwo = try await store.acquireCurrent()
        let one = try XCTUnwrap(openedOne)
        let two = try XCTUnwrap(openedTwo)
        addTeardownBlock { try await one.close(); try await two.close() }
        _ = try await fixture.publish(in: store)
        let initially = try await store.collectGarbage()
        XCTAssertEqual(initially.retained, [first.generationID!])
        try await one.close()
        let afterOne = try await store.collectGarbage()
        XCTAssertEqual(afterOne.retained, [first.generationID!])
        XCTAssertEqual(try Data(contentsOf: two.directory.appendingPathComponent(fixture.file.relativePath)), fixture.bytes)
        try await two.close()
        let afterBoth = try await store.collectGarbage()
        XCTAssertEqual(afterBoth.removed, [first.generationID!])
    }

    func testReadOnlyDescriptorsConflictWithExclusiveLockUntilAllClose() async throws {
        let paths = try ScreenSaverPaths(root: directory)
        XCTAssertEqual(chmod(paths.catalogLock.path, 0o444), 0)
        let one = try ScreenSaverFileLock.acquire(root: directory, relativePath: ".catalog.lock", mode: .shared, nonBlocking: true)
        let two = try ScreenSaverFileLock.acquire(root: directory, relativePath: ".catalog.lock", mode: .shared, nonBlocking: true)
        defer {
            XCTAssertNoThrow(try one.close())
            XCTAssertNoThrow(try two.close())
        }
        XCTAssertThrowsError(try ScreenSaverFileLock.acquire(root: directory, relativePath: ".catalog.lock", mode: .exclusive, nonBlocking: true)) {
            XCTAssertEqual($0 as? ScreenSaverFileLockError, .busy)
        }
        try one.close()
        XCTAssertThrowsError(try ScreenSaverFileLock.acquire(root: directory, relativePath: ".catalog.lock", mode: .exclusive, nonBlocking: true))
        try two.close()
        let exclusive = try ScreenSaverFileLock.acquire(root: directory, relativePath: ".catalog.lock", mode: .exclusive, nonBlocking: true)
        try exclusive.close()
    }

    func testLeaseOpenRejectsSymlinksIncludingIntermediateDirectories() async throws {
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data().write(to: outside.appendingPathComponent("lock"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias"), withDestinationURL: outside)
        XCTAssertThrowsError(try ScreenSaverFileLock.acquire(root: directory, relativePath: "alias/lock", mode: .shared, nonBlocking: true))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("alias.lock"), withDestinationURL: outside.appendingPathComponent("lock"))
        XCTAssertThrowsError(try ScreenSaverFileLock.acquire(root: directory, relativePath: "alias.lock", mode: .shared, nonBlocking: true))
    }
}
