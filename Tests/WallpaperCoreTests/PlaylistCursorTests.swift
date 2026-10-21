import XCTest
@testable import WallpaperCore

final class PlaylistCursorTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()

    func testPreparingDoesNotAdvanceAndFailureKeepsCurrent() throws {
        var cursor = PlaylistCursor(current: a)
        let proposal = try cursor.prepare(ids: [a, b], mode: .ordered)
        XCTAssertEqual(proposal.entryID, b)
        XCTAssertEqual(cursor.current, a)
        cursor.cancel()
        XCTAssertEqual(cursor.current, a)
        XCTAssertFalse(cursor.commit(proposal))
    }

    func testLatestRequestWins() throws {
        var cursor = PlaylistCursor(current: a)
        let old = try cursor.prepare(ids: [a, b, c], mode: .ordered)
        let latest = try cursor.prepare(ids: [a, b, c], mode: .ordered)
        XCTAssertFalse(cursor.commit(old))
        XCTAssertTrue(cursor.commit(latest))
        XCTAssertEqual(cursor.current, c)
    }

    func testOrderedWrapAndDeletedCurrent() throws {
        var cursor = PlaylistCursor(current: b)
        XCTAssertEqual(try cursor.prepare(ids: [a, b], mode: .ordered).entryID, a)
        cursor.cancel()
        XCTAssertEqual(try cursor.prepare(ids: [c], mode: .ordered).entryID, c)
    }

    func testRepeatCurrentAndEmptyPlaylist() throws {
        var cursor = PlaylistCursor(current: b)
        XCTAssertEqual(try cursor.prepare(ids: [a, b], mode: .repeatOne).entryID, b)
        XCTAssertThrowsError(try cursor.prepare(ids: [], mode: .ordered))
    }

    func testShuffleDoesNotRepeatWithinRoundOrAtBoundary() throws {
        var cursor = PlaylistCursor()
        var seen: [UUID] = []
        for _ in 0..<6 {
            let proposal = try cursor.prepare(ids: [a, b, c], mode: .shuffle, shuffled: { $0 })
            XCTAssertTrue(cursor.commit(proposal))
            seen.append(proposal.entryID)
        }
        XCTAssertEqual(Set(seen.prefix(3)).count, 3)
        XCTAssertEqual(Set(seen.suffix(3)).count, 3)
        XCTAssertNotEqual(seen[2], seen[3])
    }

    func testClockDoesNotConsumePausedTime() {
        var clock = PlaybackClock(duration: 30, now: 100)
        clock.pause(now: 110)
        XCTAssertEqual(clock.remaining(now: 1000), 20)
        clock.resume(now: 1000)
        XCTAssertEqual(clock.remaining(now: 1005), 15)
        clock.pause(now: 1010)
        clock.pause(now: 1020)
        XCTAssertEqual(clock.remaining(now: 1030), 10)
    }
    func testChangingDurationPreservesElapsedAndPausedTime() {
        var clock = PlaybackClock(duration: 30, now: 100)
        clock.pause(now: 110)
        clock.updateDuration(15)
        XCTAssertEqual(clock.remaining(now: 1000), 5)
        clock.resume(now: 1000)
        XCTAssertEqual(clock.remaining(now: 1004), 1)
        clock.updateDuration(10)
        XCTAssertEqual(clock.remaining(now: 1005), 0)
    }
}
