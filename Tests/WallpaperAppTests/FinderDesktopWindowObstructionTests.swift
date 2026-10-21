import AppKit
import XCTest
@testable import WallpaperApp

final class FinderDesktopWindowObstructionTests: XCTestCase {
    private let point = CGPoint(x: 100, y: 100)
    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
    private let finderPID: pid_t = 123
    private var target: FinderClickTarget {
        FinderClickTarget(screenID: "main", pageID: UUID(), windowID: 10)
    }
    private var wallpaper: FinderDesktopHitSampler.WindowInfo {
        .init(id: 10, owner: getpid(), layer: Int(CGWindowLevelForKey(.desktopWindow)) + 1, bounds: bounds)
    }
    private var finderIcons: FinderDesktopHitSampler.WindowInfo {
        .init(id: 11, owner: finderPID, layer: Int(CGWindowLevelForKey(.desktopIconWindow)), bounds: bounds)
    }

    func testVerifiedSystemCursorDoesNotObstructFinderDelivery() {
        let cursor = FinderDesktopHitSampler.WindowInfo(id: 12, owner: 456,
            layer: Int(CGWindowLevelForKey(.cursorWindow)), bounds: bounds, isSystemCursor: true)
        XCTAssertNil(FinderDesktopHitSampler.obstruction(point: point, target: target,
            windows: [cursor, finderIcons, wallpaper], finderPID: finderPID))
    }

    func testUnverifiedWindowAtCursorLevelStillObstructs() {
        let other = FinderDesktopHitSampler.WindowInfo(id: 13, owner: getpid(),
            layer: Int(CGWindowLevelForKey(.cursorWindow)), bounds: bounds)
        XCTAssertNotNil(FinderDesktopHitSampler.obstruction(point: point, target: target,
            windows: [other, finderIcons, wallpaper], finderPID: finderPID))
    }

    func testOtherWindowBelowSystemCursorStillObstructs() {
        let cursor = FinderDesktopHitSampler.WindowInfo(id: 12, owner: 456,
            layer: Int(CGWindowLevelForKey(.cursorWindow)), bounds: bounds, isSystemCursor: true)
        let overlay = FinderDesktopHitSampler.WindowInfo(id: 13, owner: getpid(), layer: 0, bounds: bounds)
        let result = FinderDesktopHitSampler.obstruction(point: point, target: target,
            windows: [cursor, overlay, finderIcons, wallpaper], finderPID: finderPID)
        XCTAssertTrue(result?.contains("窗口 13") == true)
    }
}
