import XCTest
@testable import WallpaperApp

final class BatchSelectionTests: XCTestCase {
    func testCancelAndFinishNeverKeepOldTargets() {
        let first = UUID(), second = UUID()
        var selection = BatchSelection()
        selection.toggle(first)
        XCTAssertTrue(selection.ids.isEmpty)
        selection.start(); selection.toggle(first); selection.toggle(second); selection.toggle(first)
        XCTAssertEqual(selection.ids, [second])
        selection.clear()
        XCTAssertTrue(selection.isActive)
        XCTAssertTrue(selection.ids.isEmpty)
        selection.selectAll([first, second]); selection.finish()
        XCTAssertFalse(selection.isActive)
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testSelectionTracksVisibleIDsAndCopiesAreStable() {
        let first = UUID(), second = UUID()
        var selection = BatchSelection()
        selection.start(); selection.selectAll([first, second])
        let captured = selection.ids
        selection.retain([second])
        XCTAssertEqual(selection.ids, [second])
        selection.clear()
        XCTAssertEqual(captured, [first, second], "Confirmation target snapshot must not follow later selection")
    }
}
