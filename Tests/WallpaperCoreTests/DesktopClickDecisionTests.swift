import XCTest
@testable import WallpaperCore

final class DesktopClickDecisionTests: XCTestCase {
    let instance = UUID()
    func sample(blank: Bool = true, screen: String = "display", instance: UUID? = nil) -> DesktopClickSample {
        DesktopClickSample(screenID: screen, instanceID: instance ?? self.instance, isConfirmedBlank: blank)
    }
    func testOnlyConfirmedBlankLeftClickOnCurrentInstanceIsForwarded() {
        let click = DesktopClickDecision.decide(down: sample(), up: sample(),
            state: DesktopClickState(enabled: true, visibleInstanceID: instance, isInteractive: true,
                                     button: .left, didDrag: false, clickCount: 1))
        XCTAssertEqual(click, .forward(clickCount: 1))
    }
    func testIconsLabelsWidgetsAndUnknownHitNeverForward() {
        for (down, up) in [(sample(blank: false), sample()), (sample(), sample(blank: false))] {
            XCTAssertEqual(DesktopClickDecision.decide(down: down, up: up, state: state()), .reject(.unconfirmedDesktop))
        }
    }
    func testCrossScreenAndLatePageResultsNeverReplay() {
        XCTAssertEqual(DesktopClickDecision.decide(down: sample(), up: sample(screen: "other"), state: state()), .reject(.changedTarget))
        XCTAssertEqual(DesktopClickDecision.decide(down: sample(), up: sample(instance: UUID()), state: state()), .reject(.changedTarget))
        var changed = state()
        changed.visibleInstanceID = UUID()
        XCTAssertEqual(DesktopClickDecision.decide(down: sample(), up: sample(), state: changed), .reject(.changedTarget))
    }
    func testDragRightClickAndDisabledOrTransitioningPageNeverForward() {
        var disabled = state(); disabled.enabled = false
        var transitioning = state(); transitioning.isInteractive = false
        var right = state(); right.button = .right
        var drag = state(); drag.didDrag = true
        for (value, reason) in [(disabled, DesktopClickRejection.disabled), (transitioning, .inactive),
                                (right, .unsupportedButton), (drag, .dragged)] {
            XCTAssertEqual(DesktopClickDecision.decide(down: sample(), up: sample(), state: value), .reject(reason))
        }
    }
    func testPreservesDoubleClickCountAndRejectsInvalidCount() {
        var double = state(); double.clickCount = 2
        XCTAssertEqual(DesktopClickDecision.decide(down: sample(), up: sample(), state: double), .forward(clickCount: 2))
        double.clickCount = 0
        XCTAssertEqual(DesktopClickDecision.decide(down: sample(), up: sample(), state: double), .reject(.invalidCount))
    }
    private func state() -> DesktopClickState {
        DesktopClickState(enabled: true, visibleInstanceID: instance, isInteractive: true,
                          button: .left, didDrag: false, clickCount: 1)
    }
}
