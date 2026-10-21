import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class SettingsScrollingTests: XCTestCase {
    func testGeneralScrollReceivesEventsAcrossTransparentGaps() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.setAppearance(AppAppearanceSettings(
            transparency: 1, blur: .clear, theme: .light)))
        try await fixture.show()
        let root = try XCTUnwrap(fixture.window.contentView)
        let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height, "General must overflow at its minimum height")
        let before = fixture.model.library
        var durations: [Double] = []
        for index in 0..<40 {
            // Cross both the grouped rows and their clear margins while scrolling.
            let local = NSPoint(x: index.isMultiple(of: 2) ? 12 : scroll.bounds.midX, y: scroll.bounds.midY)
            let screen = fixture.window.convertPoint(toScreen: scroll.convert(local, to: nil))
            XCTAssertEqual(NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0),
                           fixture.window.windowNumber, "The settings window must receive scroll events at \(screen)")
            let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: index < 20 ? -12 : 12, wheel2: 0, wheel3: 0))
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            let start = ContinuousClock.now
            scroll.scrollWheel(with: event)
            root.layoutSubtreeIfNeeded()
            fixture.window.displayIfNeeded()
            let elapsed = start.duration(to: .now).components
            durations.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            try await Task.sleep(for: .milliseconds(17))
            if index == 19 { XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "Wheel events must move General") }
        }
        XCTAssertEqual(fixture.model.library, before, "Scrolling must not mutate settings")
        XCTAssertTrue(fixture.window.isKeyWindow)
        print("General scrolling: max event/layout = \(durations.max()!), mean = \(durations.reduce(0, +) / Double(durations.count)) seconds")
        try await fixture.model.shutdownAndWait()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
