import AppKit
import XCTest
@testable import WallpaperApp

@MainActor
final class InspectorVisibilityTests: XCTestCase {
    func testDetailsAppearOnlyAfterSelectingAnItemAndReturnTheirSpaceWhenCleared() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        fixture.model.section = .library
        let before = fixture.model.library
        try await fixture.show(appearance: .aqua)
        XCTAssertNil(inspector(in: fixture.window), "No detail column should be present without a wallpaper selection")
        let expandedWidth = try searchWidth(in: fixture)
        let item = fixture.model.library.media[0]
        let card = try XCTUnwrap(descendants(of: fixture.window).first {
            $0.accessibilityLabel?() == item.name && ($0.accessibilityFrame?().height ?? 0) > 80
        }, "The actual wallpaper card must be accessible")
        let frame = fixture.window.convertFromScreen(try XCTUnwrap(card.accessibilityFrame?()))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: frame.midX, y: frame.midY),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            fixture.window.sendEvent(event)
        }
        try await settle()
        XCTAssertEqual(fixture.model.selectedMediaID, item.id)
        XCTAssertNotNil(inspector(in: fixture.window))
        XCTAssertGreaterThan(expandedWidth, try searchWidth(in: fixture) + 200,
                             "Hiding details must release their width to the library")
        fixture.model.selectedMediaID = nil
        try await settle()
        XCTAssertNil(inspector(in: fixture.window))
        XCTAssertEqual(try searchWidth(in: fixture), expandedWidth, accuracy: 2)
        XCTAssertNil(fixture.model.inspectorMedia.source)
        XCTAssertEqual(fixture.model.library, before)
        _ = try await fixture.capture("library-without-details")
        try await fixture.model.shutdownAndWait()
    }

    func testBatchModeNavigationAndFilteredSelectionsHideDetails() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        try await fixture.show(appearance: .aqua)
        try await fixture.waitForPlaylistControls()
        XCTAssertNotNil(inspector(in: fixture.window))
        XCTAssertEqual(try fixture.element(named: "批量选择", role: .button).accessibilityPerformPress?(), true)
        try await settle()
        XCTAssertTrue(fixture.model.batchSelection.isActive)
        XCTAssertNil(inspector(in: fixture.window), "Batch selection is not a single wallpaper detail")
        XCTAssertNil(fixture.model.inspectorMedia.source)
        fixture.model.section = .library
        try await settle()
        XCTAssertNil(inspector(in: fixture.window), "Changing sections must not reveal an old selection")
        fixture.model.selectedMediaID = fixture.model.library.media[0].id
        try await settle()
        XCTAssertNotNil(inspector(in: fixture.window))
        fixture.model.search = "no matching wallpaper"
        try await settle()
        XCTAssertNil(inspector(in: fixture.window), "A filtered-out wallpaper must not retain the detail column")
        fixture.model.section = .displays
        try await settle()
        XCTAssertNil(inspector(in: fixture.window))
        try await fixture.model.shutdownAndWait()
    }

    private func inspector(in root: AnyObject) -> AnyObject? {
        descendants(of: root).first { $0.accessibilityIdentifier?() == "wallpaper-inspector" }
    }

    private func searchWidth(in fixture: SelectionAppearanceFixture) throws -> CGFloat {
        func fields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        let field = try XCTUnwrap(fields(in: XCTUnwrap(fixture.window.contentView))
            .first { $0.placeholderString == "搜索壁纸" })
        return field.frame.width
    }

    private func descendants(of root: AnyObject) -> [AnyObject] {
        [root] + (root.accessibilityChildren?() ?? []).flatMap { descendants(of: $0 as AnyObject) }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
}
