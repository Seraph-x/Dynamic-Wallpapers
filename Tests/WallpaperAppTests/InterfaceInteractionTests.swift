import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class InterfaceInteractionTests: XCTestCase {
    func testLanguagePickerUpdatesEveryOpenWindowAndPersists() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let windows = makeContentWindows(model: fixture.model)
        defer { close(windows) }
        try await fixture.show()
        let before = fixture.model.library
        let contentViews = windows.map(\.contentView)

        for language in AppLanguage.allCases {
            try await selectLanguage(language, in: fixture)
            XCTAssertEqual(fixture.model.library.settings.language, language)
            XCTAssertEqual(try fixture.model.store.load().settings.language, language)
            XCTAssertTrue(fixture.contains(fixture.model.localizer("通用")))
            for (window, key) in zip(windows, ["导入壁纸", "视频转码"]) {
                XCTAssertTrue(contains(fixture.model.localizer.text(key), in: window),
                              "The existing window must update: \(language)/\(key)")
            }
            for (window, content) in zip(windows, contentViews) {
                XCTAssertTrue(window.contentView === content)
            }
        }
        XCTAssertEqual(fixture.model.library.media, before.media)
        XCTAssertEqual(fixture.model.library.playlists, before.playlists)
        XCTAssertEqual(fixture.model.library.displays, before.displays)
        XCTAssertEqual(fixture.model.library.settings.appearance, before.settings.appearance)
        try await fixture.model.shutdownAndWait()
    }

    func testFailedLanguageSaveKeepsSelectionAndSuccessfulRetryClearsOnlyItsError() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        let before = fixture.model.library
        let unrelated = PresentedFailure(WallpaperError("Existing playback error"), context: .playback)
        fixture.model.failure = unrelated
        try blockSaving(fixture)

        try await selectLanguage(.english, in: fixture)
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertTrue(fixture.contains("通用"))
        let picker = try languagePicker(in: fixture)
        // Check the visible value after SwiftUI rejects the failed save.
        let value = AccessibilityTestText.read("accessibilityValue", of: picker)
        XCTAssertEqual(value, AppLanguage.chinese.nativeName)
        let failure = try XCTUnwrap(fixture.model.languageFailure)
        XCTAssertTrue(fixture.contains(failure.summary))
        XCTAssertEqual(fixture.model.failure, unrelated)

        try FileManager.default.removeItem(at: fixture.model.store.url)
        try fixture.model.store.save(before)
        try await selectLanguage(.english, in: fixture)
        XCTAssertEqual(fixture.model.library.settings.language, .english)
        XCTAssertEqual(try fixture.model.store.load().settings.language, .english)
        XCTAssertTrue(fixture.contains("General"))
        XCTAssertNil(fixture.model.languageFailure)
        XCTAssertFalse(fixture.contains(failure.summary))
        XCTAssertEqual(fixture.model.failure, unrelated)
        try await fixture.model.shutdownAndWait()
    }

    func testThemePickerUpdatesOpenWindowsAndPreservesGlassSettings() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let windows = makeContentWindows(model: fixture.model)
        defer { close(windows) }
        try await fixture.show()
        fixture.window.appearance = nil
        try await fixture.selectTab("外观")
        let before = fixture.model.library
        let allWindows = windows + [fixture.window]
        let systemAppearance = try XCTUnwrap(NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))

        for (theme, title, expected) in [(AppTheme.dark, "深色", NSAppearance.Name.darkAqua),
                                        (.light, "浅色", .aqua), (.system, "跟随系统", systemAppearance)] {
            XCTAssertNotNil(try fixture.element(title, role: .radioButton).accessibilityPerformPress?())
            try await fixture.settle()
            XCTAssertEqual(fixture.model.library.settings.appearance.theme, theme)
            XCTAssertEqual(try fixture.model.store.load().settings.appearance.theme, theme)
            for window in allWindows {
                XCTAssertEqual(window.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expected)
            }
            XCTAssertEqual(fixture.model.library.settings.appearance.transparency, before.settings.appearance.transparency)
            XCTAssertEqual(fixture.model.library.settings.appearance.blur, before.settings.appearance.blur)
            XCTAssertEqual(fixture.model.library.settings.language, before.settings.language)
        }
        try await fixture.model.shutdownAndWait()
    }

    func testFailedThemeSaveKeepsThePreviousThemeSelected() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        try await fixture.selectTab("外观")
        let before = fixture.model.library
        try blockSaving(fixture)
        XCTAssertNotNil(try fixture.element("深色", role: .radioButton).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertEqual(fixture.model.library, before)
        let selected: NSNumber? = try fixture.element("跟随系统", role: .radioButton).accessibilityValue?()
        XCTAssertEqual(selected?.boolValue, true)
        XCTAssertTrue(fixture.contains(try XCTUnwrap(fixture.model.appearanceFailure).summary))
        try await fixture.model.shutdownAndWait()
    }

    private func selectLanguage(_ language: AppLanguage, in fixture: SettingsPresentationFixture) async throws {
        let picker = try languagePicker(in: fixture)
        let title = language == .system ? fixture.model.localizer("跟随系统") : language.nativeName
        let selection = LanguageMenuSelection(title: title)
        defer { selection.stop() }
        XCTAssertNotNil(picker.accessibilityPerformPress?())
        // Opening the native menu and selecting its item are separate asynchronous turns.
        // Keep the observer alive until selection finishes, not for an assumed animation duration.
        let deadline = ContinuousClock.now + .seconds(3)
        while selection.result == nil {
            guard ContinuousClock.now < deadline else {
                throw WallpaperError("The native language menu did not finish selecting \(title)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try XCTUnwrap(selection.result).get()
        try await fixture.settle()
    }

    private func languagePicker(in fixture: SettingsPresentationFixture) throws -> AnyObject {
        // macOS 27 renders the picker as a SwiftUI accessibility node, not NSPopUpButton.
        let pickers = fixture.elements.filter {
            $0.accessibilityRole?() == .popUpButton && $0.accessibilityIdentifier?() == "interface-language"
        }
        XCTAssertEqual(pickers.count, 1, "General settings must have one language popup")
        return try XCTUnwrap(pickers.first)
    }

    private func makeContentWindows(model: AppModel) -> [NSWindow] {
        [(AnyView(LibraryView(model: model, product: ProductMetadataTestSupport.product)),
          NSSize(width: 1180, height: 760)),
         (AnyView(TranscodeView(model: model)), NSSize(width: 780, height: 700))].map { content, size in
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content.appInterfacePreferences(model))
            window.orderFront(nil)
            return window
        }
    }

    private func close(_ windows: [NSWindow]) {
        for window in windows { window.contentView = nil; window.close() }
    }

    private func blockSaving(_ fixture: SettingsPresentationFixture) throws {
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try FileManager.default.createDirectory(at: fixture.model.store.url, withIntermediateDirectories: false)
    }

    private func contains(_ text: String, in element: AnyObject) -> Bool {
        let value = element.accessibilityRole?() == .staticText
            ? AccessibilityTestText.read("accessibilityValue", of: element) : nil
        if AccessibilityTestText.read("accessibilityLabel", of: element) == text
            || AccessibilityTestText.read("accessibilityTitle", of: element) == text || value == text { return true }
        return (element.accessibilityChildren?() ?? []).contains { contains(text, in: $0 as AnyObject) }
    }
}

@MainActor
private final class LanguageMenuSelection: NSObject {
    let title: String
    private(set) var result: Result<Void, Error>?
    private var timer: Timer?
    private weak var trackingMenu: NSMenu?

    init(title: String) {
        self.title = title
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    func stop() {
        timer?.invalidate()
        trackingMenu?.cancelTrackingWithoutAnimation()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        trackingMenu = notification.object as? NSMenu
        // The menu is built lazily. Select on the next turn of its tracking loop.
        let timer = Timer(timeInterval: 0, target: self, selector: #selector(selectItem(_:)),
                          userInfo: notification.object, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    @objc private func selectItem(_ timer: Timer) {
        do {
            let menu = try XCTUnwrap(timer.userInfo as? NSMenu)
            // Finish dismissing this menu before a subsequent test click opens it again.
            defer { menu.cancelTrackingWithoutAnimation() }
            let item = try XCTUnwrap(menu.item(withTitle: title),
                                    "Available languages: \(menu.items.map(\.title))")
            XCTAssertTrue(item.isEnabled)
            menu.performActionForItem(at: menu.index(of: item))
            result = .success(())
        } catch { result = .failure(error) }
    }
}
