import XCTest
@testable import WallpaperCore

final class TransitionGateTests: XCTestCase {
    func testStalePreparationCannotTransition() {
        var gate = TransitionGate()
        let a = UUID(), b = UUID()
        XCTAssertTrue(gate.request(a))
        XCTAssertTrue(gate.request(b))
        XCTAssertFalse(gate.beginTransition(a))
        XCTAssertTrue(gate.beginTransition(b))
    }
    func testDuringTransitionOnlyLatestIsQueuedWithoutThirdPreparation() {
        var gate = TransitionGate()
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertTrue(gate.request(a))
        XCTAssertTrue(gate.beginTransition(a))
        XCTAssertFalse(gate.request(b))
        XCTAssertFalse(gate.request(c))
        XCTAssertEqual(gate.finish(a), c)
        XCTAssertTrue(gate.beginTransition(c))
    }
    func testFailureAndCancellationNeverFinishAnotherRequest() {
        var gate = TransitionGate()
        let a = UUID(), b = UUID()
        _ = gate.request(a)
        _ = gate.request(b)
        gate.fail(a)
        XCTAssertTrue(gate.beginTransition(b))
    }
}
