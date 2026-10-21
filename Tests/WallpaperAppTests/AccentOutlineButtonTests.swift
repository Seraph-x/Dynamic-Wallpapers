import AppKit
import SwiftUI
import XCTest
@testable import WallpaperApp

@MainActor
final class AccentOutlineButtonTests: XCTestCase {
    func testAccentButtonsHaveTransparentCentersAndBFE2FFOutlinesInBothAppearances() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: 320, height: 180))
        fixture.window.contentView = NSHostingView(rootView: OutlineButtonProbe(isEnabled: true, action: {}))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await fixture.show(appearance: appearance)
            let button = try fixture.element(named: "应用壁纸", role: .button)
            let rect = fixture.window.convertFromScreen(try XCTUnwrap(button.accessibilityFrame?()))
            let image = try await fixture.capture("\(name)-outlined-primary-action")
            let outside = try color(at: CGPoint(x: rect.minX - 5, y: rect.midY), window: fixture.window, image: image)
            let inside = try color(at: CGPoint(x: rect.minX + 8, y: rect.midY), window: fixture.window, image: image)
            XCTAssertLessThan(distance(outside, inside), 0.025, "The button must not paint a colored fill")
            let expectedAccent = NSColor(srgbRed: 191.0 / 255, green: 226.0 / 255, blue: 1, alpha: 1)
            var accentPixels = 0
            for y in stride(from: rect.midY - 5, through: rect.midY + 5, by: 1) {
                for x in stride(from: rect.minX, through: rect.minX + 2, by: 0.5) {
                    let pixel = try color(at: CGPoint(x: x, y: y), window: fixture.window, image: image)
                    if distance(pixel, expectedAccent) < 0.04 {
                        accentPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(accentPixels, 10, "The outline must render the requested #BFE2FF blue")
            XCTAssertGreaterThanOrEqual(try fixture.actionContrast(button, image: image), 4.5)
        }
        try await fixture.model.shutdownAndWait()
    }

    func testOutlinedActionKeepsKeyboardPaddingClicksAndDisabledState() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: 320, height: 180))
        var activations = 0
        let host = NSHostingView(rootView: OutlineButtonProbe(isEnabled: true) { activations += 1 })
        fixture.window.contentView = host
        try await fixture.show(appearance: .aqua)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(fixture.window.performKeyEquivalent(with: key))
        XCTAssertEqual(activations, 1)
        let button = try fixture.element(named: "应用壁纸", role: .button)
        let rect = fixture.window.convertFromScreen(try XCTUnwrap(button.accessibilityFrame?()))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: CGPoint(x: rect.minX + 4, y: rect.midY), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            fixture.window.sendEvent(event)
        }
        XCTAssertEqual(activations, 2, "The border and padding must belong to the button's hit area")
        host.rootView = OutlineButtonProbe(isEnabled: false) { activations += 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try fixture.element(named: "应用壁纸", role: .button).isAccessibilityEnabled?(), false)
        XCTAssertFalse(fixture.window.performKeyEquivalent(with: key))
        XCTAssertEqual(activations, 2)
        try await fixture.model.shutdownAndWait()
    }

    private func color(at point: CGPoint, window: NSWindow, image: NSBitmapImageRep) throws -> NSColor {
        let scale = CGFloat(image.pixelsWide) / window.frame.width
        return try image.sRGBColor(atX: Int(point.x * scale), y: Int((window.frame.height - point.y) * scale))
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> Double {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent))
    }
}

private struct OutlineButtonProbe: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button("应用壁纸", action: action)
            .appGlassOutlinedButtonStyle()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!isEnabled)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
