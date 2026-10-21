import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SelectionAppearanceFixture {
    let model: AppModel
    let window: NSWindow
    let output: URL
    private let focusWindow: NSWindow
    private let backdrop: NSWindow?

    init(neutralBackdrop: Bool = false) throws {
        _ = NSApplication.shared
        // Keep the test process's WindowServer session stable across fixtures.
        // Reverting to .prohibited between captures invalidates ScreenCaptureKit's session.
        if NSApplication.shared.activationPolicy() != .regular {
            XCTAssertTrue(NSApplication.shared.setActivationPolicy(.regular))
        }
        output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/verification/selection-colors/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var library = Library.empty
        // Sheets apply the persisted app language independently of the root view's locale.
        library.settings.language = .chinese
        for name in ["Mountains", "Coast"] {
            let url = output.appendingPathComponent("\(name).png")
            try Self.writeImage(to: url)
            library.media.append(MediaItem(url: url, kind: .image, width: 160, height: 100))
        }
        library.playlists[0].entries = library.media.map { PlaylistEntry(mediaID: $0.id) }
        let store = LibraryStore(url: output.appendingPathComponent("library.json"))
        try store.save(library)
        model = AppModel(store: store)
        model.section = .playlist(library.playlists[0].id)
        model.selectedEntryID = library.playlists[0].entries[0].id
        model.selectedMediaID = library.media[0].id
        window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Dynamic Wallpaper — selection verification"
        window.contentView = NSHostingView(rootView: (LibraryView(
            model: model, product: ProductMetadataTestSupport.product)
            .tint(AppColors.brandAccent)).appInterfacePreferences(model))
        backdrop = neutralBackdrop ? NSWindow(contentRect: window.frame.insetBy(dx: -20, dy: -20),
            styleMask: .borderless, backing: .buffered, defer: false) : nil
        backdrop?.isReleasedWhenClosed = false
        focusWindow = NSWindow(contentRect: CGRect(x: 10, y: 10, width: 160, height: 60),
                               styleMask: [.titled], backing: .buffered, defer: false)
        focusWindow.isReleasedWhenClosed = false
        focusWindow.title = "Focus verification"
        // Earlier event pumps can mark LaunchServices ready before AppKit initializes.
        // Let NSApplication perform its own one-time initialization, as the settings fixture does.
        NSApplication.shared.finishLaunching()
        print("Selection appearance evidence: \(output.path)")
    }

    func show(appearance: NSAppearance.Name) async throws {
        let resolvedAppearance = try XCTUnwrap(NSAppearance(named: appearance))
        window.appearance = resolvedAppearance
        if let backdrop {
            // Color checks need a known surface behind a fully transparent window.
            var color: NSColor?
            resolvedAppearance.performAsCurrentDrawingAppearance {
                color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            backdrop.backgroundColor = try XCTUnwrap(color)
            backdrop.setFrame(window.frame.insetBy(dx: -20, dy: -20), display: true)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        backdrop?.order(.below, relativeTo: window.windowNumber)
        let deadline = ContinuousClock.now + .seconds(3)
        while !NSApplication.shared.isActive || !window.isKeyWindow {
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                              inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("Test window failed to activate: appActive=\(NSApplication.shared.isActive), key=\(window.isKeyWindow)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Liquid Glass animates appearance changes; sampling during that
        // transition can compare a dark label against the previous light surface.
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func waitForPlaylistControls() async throws {
        // Window activation does not imply that SwiftUI has mounted its AX tree.
        // Wait for an unrelated playlist control, not the behavior under test.
        let deadline = ContinuousClock.now + .seconds(3)
        while !Self.accessibleDescendants(of: window).contains(where: {
            $0.accessibilityRole?() == .button && ($0.accessibilityLabel?() == "重命名" || $0.accessibilityTitle?() == "重命名")
        }) {
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("Playlist controls did not become accessible")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func close() {
        window.contentView = nil
        window.close()
        focusWindow.close()
        backdrop?.close()
        model.shutdown()
    }

    func unfocus() { focusWindow.makeKeyAndOrderFront(nil) }

    func typeName(_ name: String) throws {
        let root = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(Self.descendants(of: root).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.stringValue == model.library.playlists[0].name })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(name, replacementRange: editor.selectedRange())
    }

    func key(_ character: String, code: UInt16) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    func element(named name: String, role: NSAccessibility.Role) throws -> AnyObject {
        let elements = Self.accessibleDescendants(of: window)
        return try XCTUnwrap(elements.first {
            $0.accessibilityRole?() == role && ($0.accessibilityLabel?() == name || $0.accessibilityTitle?() == name)
        }, "Missing accessible \(role.rawValue): \(name)")
    }

    var tables: [NSTableView] {
        guard let root = window.contentView else { return [] }
        return Self.descendants(of: root).compactMap { $0 as? NSTableView }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    func capture(_ name: String) async throws -> NSBitmapImageRep {
        print("Capture \(name): compositor crop for window \(window.windowNumber), visible=\(window.isVisible), key=\(window.isKeyWindow)")
        return try await WindowCompositorCapture.capture(window, to: output.appendingPathComponent("\(name).png"))
    }

    func blueCoverage(of row: Int, in table: NSTableView, image: NSBitmapImageRep,
                      dark: Bool) throws -> Double {
        let rect = table.convert(table.rect(ofRow: row), to: nil).insetBy(dx: 10, dy: 4)
        let scale = CGFloat(image.pixelsWide) / window.frame.width
        let pixels = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                            width: rect.width * scale, height: rect.height * scale)
        XCTAssertGreaterThan(pixels.width, 0)
        XCTAssertGreaterThan(pixels.height, 0)
        var matching = 0, total = 0
        for y in stride(from: Int(pixels.minY), to: Int(pixels.maxY), by: 4) {
            for x in stride(from: Int(pixels.minX), to: Int(pixels.maxX), by: 4) {
                let color = try image.sRGBColor(atX: x, y: y)
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let isSubtle = dark ? max(r, g, b) < 0.6 : min(r, g, b) > 0.7
                if isSubtle, g - r > 0.015, b - r > 0.015, b - g > 0.008, abs(g - b) < 0.1 { matching += 1 }
                total += 1
            }
        }
        guard total > 0 else { throw WallpaperError("Selection pixel sample is empty") }
        return Double(matching) / Double(total)
    }

    func actionContrast(_ action: AnyObject, image: NSBitmapImageRep) throws -> Double {
        let rect = window.convertFromScreen(try XCTUnwrap(action.accessibilityFrame?()))
        let backgroundPixels = try colors(in: rect.insetBy(dx: 1, dy: 1), image: image)
        let frequencies = Dictionary(grouping: backgroundPixels) { color in
            (Int((color.redComponent * 255).rounded()) << 16)
                | (Int((color.greenComponent * 255).rounded()) << 8)
                | Int((color.blueComponent * 255).rounded())
        }
        let background = try XCTUnwrap(frequencies.max { $0.value.count < $1.value.count }?.value.first)
        // Sample glyph interiors, excluding the native button edge and shadow.
        let textPixels = try colors(in: rect.insetBy(dx: rect.width * 0.15, dy: rect.height * 0.25), image: image)
        return try XCTUnwrap(textPixels.map { ColorContrast.ratio($0, background) }.max())
    }

    private func colors(in rect: CGRect, image: NSBitmapImageRep) throws -> [NSColor] {
        let scale = CGFloat(image.pixelsWide) / window.frame.width
        let bounds = CGRect(x: rect.minX * scale, y: (window.frame.height - rect.maxY) * scale,
                            width: rect.width * scale, height: rect.height * scale)
        var result: [NSColor] = []
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                result.append(try image.sRGBColor(atX: x, y: y))
            }
        }
        return result
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func accessibleDescendants(of element: AnyObject) -> [AnyObject] {
        // SwiftUI accessibility nodes implement these public Objective-C methods
        // without declaring NSAccessibilityProtocol conformance.
        let children: [AnyObject]
        if let object = element as? NSObject,
           !object.responds(to: NSSelectorFromString("accessibilityChildren")),
           object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) {
            // AppKit's NSOutlineRow / NSOutlineCell still expose the legacy AX API.
            children = object.perform(NSSelectorFromString("accessibilityAttributeValue:"),
                with: NSAccessibility.Attribute.children.rawValue)?.takeUnretainedValue() as? [AnyObject] ?? []
        } else { children = (element.accessibilityChildren?() ?? []).map { $0 as AnyObject } }
        return [element] + children.flatMap { accessibleDescendants(of: $0) }
    }

    private static func writeImage(to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8,
            bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
