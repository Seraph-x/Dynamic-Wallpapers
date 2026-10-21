import XCTest
@testable import WallpaperApp

final class FinderDesktopClickDecisionTests: XCTestCase {
    private let target = FinderClickTarget(screenID: "display", pageID: UUID(), windowID: 42)

    private func sample(menu: FinderMenuEvidence, roles: [String] = ["AXGroup", "AXScrollArea", "AXApplication"],
                        clear: Bool = true, destination: FinderMouseDestination = .finder) -> FinderDesktopSample {
        FinderDesktopSample(target: target, menu: menu, roles: roles, allOwnersAreFinder: true,
                            completeAncestry: true, windowsClear: clear, destination: destination)
    }

    func testRealMenuDismissSequenceCannotBecomeClickButNextIndependentPairCan() {
        var menu = FinderMenuEvidence()
        menu.opened()
        let downClosingMenu = sample(menu: menu)
        menu.closed()
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: downClosingMenu, up: sample(menu: menu),
            currentMenu: menu, currentTarget: target, didDrag: false, clickCount: 1), .reject(.menuChanged))
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: sample(menu: menu), up: sample(menu: menu),
            currentMenu: menu, currentTarget: target, didDrag: false, clickCount: 1), .forward)
    }

    func testUnknownInitialMenuIsNotAssumedClosed() {
        let menu = FinderMenuEvidence()
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: sample(menu: menu), up: sample(menu: menu),
            currentMenu: menu, currentTarget: target, didDrag: false, clickCount: 1), .reject(.menuUnknown))
    }

    func testFirstCompleteMenuSnapshotEnablesWithoutCalibration() {
        var menu = FinderMenuEvidence()
        XCTAssertTrue(menu.apply(.closed, ifUnchanged: menu.generation))
        XCTAssertEqual(menu.state, .observedClosed)
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: sample(menu: menu), up: sample(menu: menu),
            currentMenu: menu, currentTarget: target, didDrag: false, clickCount: 1), .forward)
    }

    func testAlreadyOpenMenuRemainsBlockedUntilCompleteClosedSnapshot() {
        var menu = FinderMenuEvidence()
        XCTAssertTrue(menu.apply(.open, ifUnchanged: menu.generation))
        XCTAssertEqual(menu.state, .open)
        menu.invalidate() // Closing a submenu does not prove every menu has closed.
        XCTAssertEqual(menu.state, .unknown)
        XCTAssertTrue(menu.apply(.closed, ifUnchanged: menu.generation))
        XCTAssertEqual(menu.state, .observedClosed)
    }

    func testMenuSnapshotCannotOverwriteLaterNotification() {
        var menu = FinderMenuEvidence()
        let generation = menu.generation
        menu.opened()
        XCTAssertFalse(menu.apply(.closed, ifUnchanged: generation))
        XCTAssertEqual(menu.state, .open)
    }

    func testRepeatedClosedSnapshotKeepsInFlightClickGeneration() {
        var menu = FinderMenuEvidence()
        menu.closed()
        let generation = menu.generation
        XCTAssertTrue(menu.apply(.closed, ifUnchanged: generation))
        XCTAssertEqual(menu.generation, generation)
    }

    func testSnapshotFailureIsExplicitAndRevokesClosedEvidence() {
        var menu = FinderMenuEvidence()
        menu.closed()
        XCTAssertTrue(menu.apply(.unavailable("AX selected children: -25204"), ifUnchanged: menu.generation))
        XCTAssertEqual(menu.state, .unknown)
        XCTAssertEqual(menu.failureReason, "AX selected children: -25204")
    }

    func testOtherApplicationAndUnknownEventDestinationsCannotBecomeDesktopClicks() {
        var menu = FinderMenuEvidence()
        menu.closed()
        for destination in [FinderMouseDestination.otherProcess, .unavailable] {
            XCTAssertEqual(FinderDesktopClickDecision.decide(down: sample(menu: menu, destination: destination),
                up: sample(menu: menu), currentMenu: menu, currentTarget: target, didDrag: false, clickCount: 1),
                .reject(.eventNotFinder))
            XCTAssertEqual(FinderDesktopClickDecision.decide(down: sample(menu: menu),
                up: sample(menu: menu, destination: destination), currentMenu: menu, currentTarget: target,
                didDrag: false, clickCount: 1), .reject(.eventNotFinder))
        }
    }

    func testSamePageAfterTransientNoninteractivePhaseRejectsOldClick() {
        var menu = FinderMenuEvidence()
        menu.closed()
        let resumed = FinderClickTarget(screenID: target.screenID, pageID: target.pageID, windowID: target.windowID)
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: sample(menu: menu), up: sample(menu: menu),
            currentMenu: menu, currentTarget: resumed, didDrag: false, clickCount: 1), .reject(.targetChanged))
    }

    func testIconsLabelsAndOtherWindowsAreNotBlankDesktop() {
        var menu = FinderMenuEvidence(); menu.closed()
        for role in ["AXImage", "AXStaticText", "AXMenuItem", "AXWindow"] {
            XCTAssertEqual(FinderDesktopClickDecision.decide(down: sample(menu: menu, roles: [role, "AXGroup", "AXScrollArea", "AXApplication"]),
                up: sample(menu: menu), currentMenu: menu, currentTarget: target, didDrag: false, clickCount: 1), .reject(.notFinderDesktop))
        }
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: sample(menu: menu), up: sample(menu: menu, clear: false),
            currentMenu: menu, currentTarget: target, didDrag: false, clickCount: 1), .reject(.windowObscured))
    }

    func testLateResultDragAndChangedPageCannotForward() {
        var menu = FinderMenuEvidence(); menu.closed()
        let down = sample(menu: menu)
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: down, up: down, currentMenu: menu,
            currentTarget: FinderClickTarget(screenID: target.screenID, pageID: UUID(), windowID: target.windowID),
            didDrag: false, clickCount: 1), .reject(.targetChanged))
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: down, up: down, currentMenu: menu,
            currentTarget: target, didDrag: true, clickCount: 1), .reject(.dragged))
        menu.opened(); menu.closed()
        XCTAssertEqual(FinderDesktopClickDecision.decide(down: down, up: down, currentMenu: menu,
            currentTarget: target, didDrag: false, clickCount: 1), .reject(.menuChanged))
    }
}
