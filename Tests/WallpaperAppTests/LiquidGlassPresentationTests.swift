import AppKit
import XCTest
@testable import WallpaperApp

@MainActor
final class LiquidGlassPresentationTests: XCTestCase {
    func testAllColumnsShareTheWindowGlassBackdropWhileInactive() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.model.section = .library
        fixture.model.selectedMediaID = fixture.model.library.media[0].id
        try await fixture.show(appearance: .aqua)
        let backdrop = NSWindow(contentRect: fixture.window.frame.insetBy(dx: -40, dy: -40),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        defer { backdrop.close() }
        backdrop.order(.below, relativeTo: fixture.window.windowNumber)

        var samples: [(sidebar: NSColor, content: NSColor, inspector: NSColor)] = []
        for (name, color) in [("red", NSColor.systemRed), ("blue", NSColor.systemBlue)] {
            backdrop.backgroundColor = color
            try await fixture.show(appearance: .aqua)
            fixture.unfocus()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertFalse(fixture.window.isKeyWindow)
            let image = try await fixture.capture("glass-backdrop-\(name)")
            let inspector = try element(id: "inspector-content", in: fixture.window)
            let inspectorFrame = fixture.window.convertFromScreen(try XCTUnwrap(inspector.accessibilityFrame?()))
                .intersection(try XCTUnwrap(fixture.window.contentView).bounds)
            let inspectorMargin = CGRect(x: inspectorFrame.minX + 4, y: inspectorFrame.midY - 25, width: 5, height: 50)
            samples.append((try averageColor(in: CGRect(x: 50, y: 150, width: 80, height: 100),
                                             window: fixture.window, image: image),
                            try averageColor(in: CGRect(x: 350, y: 150, width: 80, height: 100),
                                             window: fixture.window, image: image),
                            try averageColor(in: inspectorMargin, window: fixture.window, image: image)))
        }
        let sidebarDelta = distance(samples[0].sidebar, samples[1].sidebar)
        let contentDelta = distance(samples[0].content, samples[1].content)
        let inspectorDelta = distance(samples[0].inspector, samples[1].inspector)
        let reducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        print("Glass backdrop deltas: sidebar=\(sidebarDelta), content=\(contentDelta), inspector=\(inspectorDelta), reduceTransparency=\(reducesTransparency)")
        for (column, delta) in [("sidebar", sidebarDelta), ("content", contentDelta), ("inspector", inspectorDelta)] {
            if reducesTransparency {
                XCTAssertLessThan(delta, 0.01, "The \(column) must honor Reduce Transparency")
            } else {
                XCTAssertGreaterThan(delta, 0.02, "The \(column) must sample colors behind the window")
            }
        }
    }

    func testPlaylistAndInspectorPreserveActionsAtMinimumWindowSize() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        let before = fixture.model.library
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await fixture.show(appearance: appearance)
            fixture.window.setContentSize(NSSize(width: 1000, height: 650))
            try await Task.sleep(for: .milliseconds(300))
            _ = try element(id: "inspector-content", in: fixture.window)
            let image = try await fixture.capture("\(name)-liquid-glass-minimum")
            for title in ["应用播放列表", "应用壁纸"] {
                let button = try fixture.element(named: title, role: .button)
                XCTAssertEqual(button.isAccessibilityEnabled?(), true)
                let frame = fixture.window.convertFromScreen(try XCTUnwrap(button.accessibilityFrame?()))
                let border = try averageColor(in: CGRect(x: frame.minX + 0.25, y: frame.midY - 5, width: 0.5, height: 10),
                                              window: fixture.window, image: image)
                XCTAssertGreaterThan(border.greenComponent - border.redComponent, 0.08, "\(title) must retain its blue outline")
                XCTAssertGreaterThan(border.blueComponent - border.redComponent, 0.04)
                XCTAssertGreaterThan(border.blueComponent - border.greenComponent, 0.06)
                let inside = try averageColor(in: CGRect(x: frame.minX + 4, y: frame.midY - 5, width: 2, height: 10),
                                              window: fixture.window, image: image)
                let outside = try averageColor(in: CGRect(x: frame.minX - 4, y: frame.midY - 5, width: 2, height: 10),
                                               window: fixture.window, image: image)
                XCTAssertLessThan(distance(inside, outside), 0.025, "\(title) must have a transparent center")
                XCTAssertGreaterThanOrEqual(try fixture.actionContrast(button, image: image), 4.5,
                                            "\(title) must retain readable text on the window backdrop")
            }
        }
        XCTAssertEqual(fixture.tables.count, 2)
        // The native toolbar's AX wrapper can return false after dispatching an action.
        // Exercise the system shortcut and verify the actual column visibility instead.
        let shortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        for expectedTableCount in [1, 2] {
            let toggle = try fixture.element(named: "切换侧边栏", role: .button)
            XCTAssertEqual(toggle.isAccessibilityEnabled?(), true)
            XCTAssertTrue(fixture.window.performKeyEquivalent(with: shortcut))
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(fixture.tables.count, expectedTableCount, "Sidebar visibility must remain controllable")
            _ = try element(id: "inspector-content", in: fixture.window)
        }
        XCTAssertFalse(fixture.model.userPaused)
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertEqual(try fixture.model.store.load(), before)
    }

    func testCompactGlassControlsIncludePaddingInTheirClickTargets() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let before = fixture.model.library
        try await fixture.show(appearance: .aqua)
        for (title, expectedActive) in [("批量选择", true), ("完成", false)] {
            let button = try fixture.element(named: title, role: .button)
            let frame = fixture.window.convertFromScreen(try XCTUnwrap(button.accessibilityFrame?()))
            let paddingPoint = CGPoint(x: frame.minX + 3, y: frame.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: paddingPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                fixture.window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(fixture.model.batchSelection.isActive, expectedActive,
                           "The glass padding must be part of the button hit target")
        }
        XCTAssertEqual(fixture.model.library, before)
    }

    private func averageColor(in rect: CGRect, window: NSWindow, image: NSBitmapImageRep) throws -> NSColor {
        let scale = CGFloat(image.pixelsWide) / window.frame.width
        let pixels = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                            width: rect.width * scale, height: rect.height * scale)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in stride(from: Int(pixels.minY), to: Int(pixels.maxY), by: 4) {
            for x in stride(from: Int(pixels.minX), to: Int(pixels.maxX), by: 4) {
                let color = try image.sRGBColor(atX: x, y: y)
                red += color.redComponent; green += color.greenComponent; blue += color.blueComponent
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 0)
        return NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1)
    }

    private func distance(_ first: NSColor, _ second: NSColor) -> Double {
        max(abs(first.redComponent - second.redComponent), abs(first.greenComponent - second.greenComponent),
            abs(first.blueComponent - second.blueComponent))
    }

    private func element(id: String, in root: AnyObject) throws -> AnyObject {
        func find(_ element: AnyObject) -> AnyObject? {
            if element.accessibilityIdentifier?() == id { return element }
            return (element.accessibilityChildren?() ?? []).lazy.compactMap { find($0 as AnyObject) }.first
        }
        return try XCTUnwrap(find(root), "Missing accessible element: \(id)")
    }
}
