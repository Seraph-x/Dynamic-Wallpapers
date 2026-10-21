import AppKit
import XCTest
@testable import WallpaperApp

@MainActor
final class ManagementWindowSpaceBehaviorTests: XCTestCase {
    func testBridgeMovesManagementWindowToActiveSpaceWithoutLosingFullScreenBehavior() {
        let window = makeWindow()
        defer { window.close() }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary, .participatesInCycle]

        window.contentView = ManagementWindowSpaceBehavior.WindowView()

        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertTrue(window.collectionBehavior.contains(.participatesInCycle))
    }

    func testBridgeReappliesRoutingAfterSceneUpdateAndReattachment() async throws {
        let first = makeWindow()
        let second = makeWindow()
        let view = ManagementWindowSpaceBehavior.WindowView()
        defer { first.close(); second.close() }
        first.contentView = view
        first.contentView = nil
        second.contentView = view
        first.collectionBehavior = .canJoinAllSpaces
        second.collectionBehavior = .canJoinAllSpaces

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        let deadline = ContinuousClock.now + .seconds(1)
        while !second.collectionBehavior.contains(.moveToActiveSpace), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(second.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(second.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(first.collectionBehavior, .canJoinAllSpaces,
                       "A detached management window must not be reconfigured")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
