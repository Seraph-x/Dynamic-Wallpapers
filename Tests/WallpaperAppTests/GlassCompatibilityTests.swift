import AppKit
import SwiftUI
import XCTest
@testable import WallpaperApp

@MainActor
final class GlassCompatibilityTests: XCTestCase {
    func testCompactStyleRetainsNativeKeyboardShortcutsAndDisabledState() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        var activations = 0
        let host = NSHostingView(rootView: ShortcutProbe(isEnabled: true) { activations += 1 })
        fixture.window.contentView = host
        try await fixture.show(appearance: .aqua)
        // Explicit shortcuts work independently of the user's Full Keyboard
        // Access setting; do not change that global preference for a test.
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
            context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
        XCTAssertTrue(fixture.window.performKeyEquivalent(with: key))
        XCTAssertEqual(activations, 1)
        host.rootView = ShortcutProbe(isEnabled: false) { activations += 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try fixture.element(named: "玻璃按钮", role: .button).isAccessibilityEnabled?(), false)
        XCTAssertFalse(fixture.window.performKeyEquivalent(with: key))
        XCTAssertEqual(activations, 1, "A disabled glass control must not invoke its action")
    }

    func testNativeBackgroundsKeepTheirMaterialWhenTheWindowIsInactive() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let expected: [(AppGlassSurface, NSVisualEffectView.Material, NSVisualEffectView.BlendingMode)] = [
            (.window, .sidebar, .behindWindow), (.control, .popover, .withinWindow)
        ]
        for (surface, material, blending) in expected {
            let host = NSHostingView(rootView: NativeVisualEffectBackground(
                material: surface.legacyMaterial, blendingMode: surface.blendingMode))
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let effect = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSVisualEffectView }.first)
            XCTAssertEqual(effect.material, material)
            XCTAssertEqual(effect.blendingMode, blending)
            XCTAssertEqual(effect.state, .active, "Opening another app window must not deactivate its glass backdrop")
            XCTAssertFalse(effect.isEmphasized)

            host.rootView = NativeVisualEffectBackground(material: .headerView, blendingMode: .withinWindow)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(effect.material, .headerView, "SwiftUI updates must reconfigure the existing native view")
            XCTAssertEqual(effect.blendingMode, .withinWindow)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

private struct ShortcutProbe: View {
    let isEnabled: Bool
    let onActivate: () -> Void

    var body: some View {
        Button("玻璃按钮", action: onActivate)
            .appGlassControlStyle()
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(!isEnabled)
            .padding(40)
    }
}
