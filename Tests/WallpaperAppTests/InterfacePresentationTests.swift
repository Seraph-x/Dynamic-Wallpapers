import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class InterfacePresentationTests: XCTestCase {
    func testChangingLanguageUpdatesTheOpenSettingsWindow() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.setLanguage(.chinese))
        try await fixture.show()
        XCTAssertTrue(fixture.contains("通用"))
        let window = fixture.window
        for (language, general, appearance) in [
            (AppLanguage.english, "General", "Appearance"), (.japanese, "一般", "外観"),
            (.french, "Général", "Apparence"), (.spanish, "General", "Apariencia"),
            (.chinese, "通用", "外观")
        ] {
            XCTAssertTrue(fixture.model.setLanguage(language))
            try await fixture.settle()
            let labels: [String] = fixture.elements.compactMap { element in
                let label: String? = element.accessibilityLabel?()
                let title: String? = element.accessibilityTitle?()
                let value: String? = element.accessibilityRole?() == .staticText ? element.accessibilityValue?() : nil
                return label ?? title ?? value
            }
            try "translator=\(fixture.model.localizer("通用"))\n\(labels.joined(separator: "\n"))"
                .write(to: fixture.output.appendingPathComponent("\(language.rawValue)-labels.txt"), atomically: true, encoding: .utf8)
            _ = try await fixture.capture("\(language.rawValue)-settings")
            XCTAssertTrue(fixture.contains(general), "Missing \(language) general tab")
            XCTAssertTrue(fixture.contains(appearance), "Missing \(language) appearance tab")
            for key in ["存储与素材", "高级", "关于"] {
                let tab = try fixture.element(fixture.model.localizer.text(key), role: .button)
                XCTAssertTrue(fixture.window.frame.contains(try XCTUnwrap(tab.accessibilityFrame?())),
                              "Every localized tab must remain visible: \(language)/\(key)")
            }
            XCTAssertTrue(window === fixture.window)
            XCTAssertEqual(try fixture.model.store.load().settings.language, language)
        }
        try await fixture.model.shutdownAndWait()
    }

    func testThemeControlsAreAvailableBesideTheExistingGlassSettings() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.setLanguage(.chinese))
        try await fixture.show()
        try await fixture.selectTab("外观")
        for title in ["跟随系统", "浅色", "深色", "背景透明度", "模糊效果", "全屏背景帧率"] {
            XCTAssertTrue(fixture.contains(title), "Missing appearance control: \(title)")
        }
        try await fixture.model.shutdownAndWait()
    }
}
