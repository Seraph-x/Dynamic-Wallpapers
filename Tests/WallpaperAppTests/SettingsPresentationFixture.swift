import XCTest
import SwiftUI
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SettingsPresentationFixture {
    let model: AppModel
    let window: NSWindow
    let output: URL

    init(content: ((AppModel) -> AnyView)? = nil, presentation: TestApplicationPresentation? = nil,
         loginService: TestLoginItemService? = nil,
         webInteractionPermissions: (any WebInteractionPermissionServicing)? = nil,
         setSystemDesktopImage: @escaping @MainActor (URL, String) throws -> Void = { _, _ in
             XCTFail("A settings test attempted an unexpected system wallpaper write")
             throw WallpaperError("Unexpected system wallpaper write in settings test")
         }) throws {
        _ = NSApplication.shared
        if NSApplication.shared.activationPolicy() != .regular {
            XCTAssertTrue(NSApplication.shared.setActivationPolicy(.regular))
        }
        output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/verification/settings-tabs/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = LibraryStore(url: output.appendingPathComponent("library-extended.json"))
        var library = Library.empty
        library.settings.language = .chinese
        try store.save(library)
        model = AppModel(store: store, presentation: presentation ?? TestApplicationPresentation(),
                         loginItems: LoginItemController(service: loginService ?? TestLoginItemService()),
                         webInteractionPermissions: webInteractionPermissions,
                         setSystemDesktopImage: setSystemDesktopImage)
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: SettingsView.minimumSize),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Dynamic Wallpaper — settings verification"
        window.contentView = NSHostingView(rootView: (content?(model)
            ?? AnyView(SettingsView(model: model, product: ProductMetadataTestSupport.product)
                .tint(AppColors.brandAccent)))
            .appInterfacePreferences(model))
        // LaunchServices can report ready before this XCTest process initializes AppKit.
        // Let NSApplication handle its own one-time initialization, even after earlier event pumps.
        NSApplication.shared.finishLaunching()
        print("Settings presentation evidence: \(output.path)")
    }

    func show(appearance: NSAppearance.Name = .aqua, readyText: String? = nil) async throws {
        try await activateWindow(appearance: appearance)
        let accessibilityDeadline = ContinuousClock.now + .seconds(3)
        while !(readyText.map { contains($0) }
            ?? elements.contains(where: { $0.accessibilityIdentifier?() == "settings-tab-appearance" })) {
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                              inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard ContinuousClock.now < accessibilityDeadline else {
                throw WallpaperError("Expected presentation controls did not become accessible: \(readyText ?? "settings-tab-appearance")")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle()
    }

    // Background-only fixtures have no accessibility controls to await.
    func showWindow(appearance: NSAppearance.Name = .aqua) async throws {
        try await activateWindow(appearance: appearance)
        try await settle()
        let content = try XCTUnwrap(window.contentView)
        guard content.window === window, !content.bounds.isEmpty else {
            throw WallpaperError("Presentation window content was not mounted")
        }
    }

    private func activateWindow(appearance: NSAppearance.Name) async throws {
        window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while !NSApplication.shared.isActive || !window.isKeyWindow {
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                              inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("Settings test window failed to activate")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.contentView = nil
        window.close()
        model.shutdown()
    }

    var elements: [AnyObject] { Self.descendants(of: window) }

    func contains(_ text: String) -> Bool { elements.contains { Self.matches($0, text: text) } }

    func element(_ text: String, role: NSAccessibility.Role? = nil) throws -> AnyObject {
        try XCTUnwrap(elements.first {
            (role == nil || $0.accessibilityRole?() == role) && Self.matches($0, text: text)
        }, "Missing settings element: \(text)")
    }

    func selectTab(_ title: String) async throws {
        let tab = try element(title, role: .button)
        XCTAssertNotNil(tab.accessibilityPerformPress?())
        try await settle()
        XCTAssertEqual(tab.isAccessibilitySelected?(), true, "Tab did not become selected: \(title)")
    }

    func capture(_ name: String) async throws -> URL {
        let url = output.appendingPathComponent("\(name).png")
        _ = try await WindowCompositorCapture.capture(window, to: url)
        return url
    }

    private static func matches(_ element: AnyObject, text: String) -> Bool {
        let value = element.accessibilityRole?() == .staticText
            ? AccessibilityTestText.read("accessibilityValue", of: element) : nil
        let titleElement = element.accessibilityTitleUIElement?() as AnyObject?
        let linkedTitle = AccessibilityTestText.read("accessibilityValue", of: titleElement)
        return AccessibilityTestText.read("accessibilityLabel", of: element) == text
            || AccessibilityTestText.read("accessibilityTitle", of: element) == text
            || value == text || linkedTitle == text
    }

    private static func descendants(of element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).flatMap { descendants(of: $0 as AnyObject) }
    }
}
