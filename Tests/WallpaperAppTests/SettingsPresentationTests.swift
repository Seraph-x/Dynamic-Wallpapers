import AppKit
import SwiftUI
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class SettingsPresentationTests: XCTestCase {
    private let systemEvents = "锁屏或休眠时自动暂停。"
    private let storageExplanation = "新导入的文件会复制到应用的 Media 目录，网页会复制整个项目；移动或删除原文件不影响副本播放。"
    private let migrationExplanation = "新版兼容读取旧配置；保存后的新版素材库无法由旧程序读取。"

    func testSettingsStartOnGeneralWithFiveTabsAndNoDiagnosticContent() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()

        for title in ["通用", "外观", "存储与素材", "高级", "关于"] {
            XCTAssertTrue(fixture.contains(title), "Missing settings tab: \(title)")
        }
        for title in ["启动与运行", "登录时启动", "在 Dock 中显示应用图标", "声音", "全局静音", "节能", "低电量模式时暂停", "设备温度较高时暂停", "系统事件"] {
            XCTAssertTrue(fixture.contains(title), "Missing General setting or section: \(title)")
        }
        XCTAssertFalse(fixture.contains("本地素材"))
        XCTAssertFalse(fixture.contains("在 Finder 中显示"))
        XCTAssertFalse(fixture.contains("原生界面 · 本地优先 · 默认静音"))
        XCTAssertTrue(fixture.contains(systemEvents))
        XCTAssertFalse(fixture.contains(WallpaperCopy.pauseHelp))
        XCTAssertEqual(try fixture.element("暂停与恢复说明", role: .button).accessibilityHelp?(), WallpaperCopy.pauseHelp)
        for text in ["全局静音说明", "同时静音桌面壁纸和预览。", fixture.model.loginItems.statusMessage,
                     "关闭后仍在菜单栏运行，可从菜单栏打开窗口或退出。",
                     "立即应用到所有窗口和菜单。跟随系统时按语言偏好匹配，不支持的语言使用英语。"] {
            XCTAssertFalse(fixture.contains(text), "General must not show explanatory copy: \(text)")
        }
        XCTAssertEqual(fixture.elements.filter { $0.accessibilityRole?() == .checkBox }.count, 8,
                       "General exposes eight switches including system audio; System Events remains informational")
        _ = try fixture.element("系统音频响应", role: .checkBox)
        XCTAssertEqual(fixture.elements.filter { $0.accessibilityRole?() == .radioButton }.count, 3,
                       "System media offers three source choices without another switch")
        XCTAssertEqual(try fixture.model.store.load(), fixture.model.library)
        try await fixture.model.shutdownAndWait()
    }

    func testAppearanceTabProvidesThemeAndBackgroundControls() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        try await fixture.selectTab("外观")
        _ = try fixture.element("背景透明度", role: .slider)
        _ = try fixture.element("主题颜色", role: .colorWell)
        let codeField = try fixture.element("颜色代码", role: .textField)
        let codeLabel = try fixture.element("颜色代码", role: .staticText)
        let fieldFrame = try XCTUnwrap(codeField.accessibilityFrame?())
        let labelFrame = try XCTUnwrap(codeLabel.accessibilityFrame?())
        XCTAssertEqual(labelFrame.midX, fieldFrame.midX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(labelFrame.minY, fieldFrame.maxY)
        XCTAssertEqual((codeField as? NSTextFieldCell)?.alignment, .center)
        for text in ["模糊效果", "清透", "磨砂", "全屏背景帧率", "30 Hz", "60 Hz",
                     "网页壁纸帧率", "24 FPS", "30 FPS", "60 FPS"] {
            XCTAssertTrue(fixture.contains(text), "Missing appearance control: \(text)")
        }
        for text in ["0% 为不透明，100% 为纯透明，不模糊窗口后方。",
                     "仅在活动的全屏桌面采集背景。30 Hz 更省资源，60 Hz 更流畅；实际帧率受系统和素材影响。",
                     "同时应用到主窗口、设置和转码窗口，文字及控件保持清晰。"] {
            XCTAssertFalse(fixture.contains(text), "Appearance must not show explanatory copy: \(text)")
        }
        XCTAssertFalse(fixture.elements.contains {
            $0.accessibilityHelp?() == "透明度低于 100% 时使用所选模糊效果。"
        })
        XCTAssertFalse(fixture.contains("全局静音"))
        XCTAssertEqual(try fixture.model.store.load(), fixture.model.library)
        try await fixture.model.shutdownAndWait()
    }

    func testTabsSeparateStorageDiagnosticsAndBrandingWithoutMutatingLibrary() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let before = fixture.model.library
        try await fixture.show()

        try await fixture.selectTab("存储与素材")
        XCTAssertTrue(fixture.contains("本地素材"))
        XCTAssertTrue(fixture.contains(storageExplanation))
        XCTAssertFalse(fixture.contains("旧素材仍从原位置读取，不会自动迁移。"))
        XCTAssertFalse(fixture.contains("全局静音"))
        XCTAssertFalse(fixture.contains("在 Finder 中显示"))
        XCTAssertFalse(fixture.contains(migrationExplanation))

        try await fixture.selectTab("高级")
        for text in ["仅供排查问题时参考", "配置文件", "文件名", "library-extended.json",
                     "素材库格式版本", String(before.version), "完整路径", fixture.model.store.url.path] {
            XCTAssertTrue(fixture.contains(text), "Missing Advanced information: \(text)")
        }
        XCTAssertEqual(try fixture.element("在 Finder 中显示").isAccessibilityEnabled?(), true)
        for text in ["迁移与回退", "迁移详情", migrationExplanation] {
            XCTAssertFalse(fixture.contains(text), "Advanced must not show migration information: \(text)")
        }
        XCTAssertFalse(fixture.contains(storageExplanation))
        XCTAssertFalse(fixture.contains("原生界面 · 本地优先 · 默认静音"))

        try await fixture.selectTab("关于")
        for text in ["Dynamic Wallpaper", "Dynamic Wallpaper 应用图标", "原生界面 · 本地优先 · 默认静音"] {
            XCTAssertTrue(fixture.contains(text), "Missing About information: \(text)")
        }
        for text in ["素材库格式版本", "在 Finder 中显示", "检查更新", "反馈问题"] {
            XCTAssertFalse(fixture.contains(text), "Unexpected About content: \(text)")
        }
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertEqual(try fixture.model.store.load(), before)
        try await fixture.model.shutdownAndWait()
    }

    func testGeneralTogglesPersistAcrossTabChanges() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        var expected = fixture.model.library.settings
        let settings: [(String, WritableKeyPath<AppSettings, Bool>)] = [
            ("全局静音", \.isMuted), ("低电量模式时暂停", \.pauseOnLowPower),
            ("设备温度较高时暂停", \.pauseOnHighTemperature)
        ]
        for (title, keyPath) in settings {
            expected[keyPath: keyPath].toggle()
            // Native NSSwitch can return false after dispatching the action, too.
            // Verify the actual model, disk and rendered switch state instead.
            XCTAssertNotNil(try fixture.element(title, role: .checkBox).accessibilityPerformPress?())
            try await fixture.settle()
            XCTAssertEqual(fixture.model.library.settings, expected)
            XCTAssertEqual(try fixture.model.store.load().settings, expected)
            let value: NSNumber? = try fixture.element(title, role: .checkBox).accessibilityValue?()
            XCTAssertEqual(try XCTUnwrap(value).boolValue, expected[keyPath: keyPath])
            XCTAssertTrue(fixture.contains(systemEvents))
        }
        try await fixture.selectTab("高级")
        try await fixture.selectTab("通用")
        XCTAssertEqual(fixture.model.library.settings, expected)
        for (title, keyPath) in settings {
            let value: NSNumber? = try fixture.element(title, role: .checkBox).accessibilityValue?()
            XCTAssertEqual(try XCTUnwrap(value).boolValue, expected[keyPath: keyPath])
        }
        XCTAssertTrue(fixture.contains(systemEvents))
        try await fixture.model.shutdownAndWait()
    }

    func testFiveTabsFitInBothAppearancesWithoutResizing() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        let tabs = [("通用", "general"), ("外观", "appearance"), ("存储与素材", "storage"),
                    ("高级", "advanced"), ("关于", "about")]
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try await fixture.show(appearance: appearance)
            let size = fixture.window.frame.size
            for (tab, slug) in tabs {
                try await fixture.selectTab(tab)
                XCTAssertEqual(fixture.window.frame.size, size)
                // All tabs must fit; General intentionally scrolls at its minimum height
                // (covered by SettingsScrollingTests), so offscreen form rows need not fit.
                let tabElements = try tabs.map { try fixture.element($0.0, role: .button) }
                let pageText = tab == "通用" ? [] : fixture.elements.filter { $0.accessibilityRole?() == .staticText }
                for element in tabElements + pageText {
                    let frame = try XCTUnwrap(element.accessibilityFrame?())
                    XCTAssertGreaterThan(frame.width, 0)
                    XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertTrue(fixture.window.frame.contains(frame), "Settings text must fit: \(tab), \(frame)")
                }
                if tab == "高级" {
                    let path = try fixture.element(fixture.model.store.url.path)
                    XCTAssertGreaterThan(try XCTUnwrap(path.accessibilityFrame?()).height, 20,
                                         "The full configuration path must wrap instead of truncating")
                }
                _ = try await fixture.capture("\(name)-\(slug)")
            }
        }
        try await fixture.model.shutdownAndWait()
    }

    func testAboutReadsTheInjectedProductVersion() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        for version in ["9.8.7", "1.2.3-beta"] {
            var info = try ProductMetadataTestSupport.information()
            info["CFBundleShortVersionString"] = version
            let bundle = try ProductMetadataTestSupport.makeBundle(
                in: fixture.output.appendingPathComponent(UUID().uuidString), information: info)
            let product = try ProductBundleMetadata(bundle: bundle)
            fixture.window.contentView = NSHostingView(rootView: (AboutSettingsView(product: product))
                .environment(\.locale, Locale(identifier: "zh-Hans")))
            try await fixture.show(readyText: "版本 \(version)")
            XCTAssertTrue(fixture.contains("版本 \(version)"))
            XCTAssertFalse(fixture.contains("版本信息不可用"))
            XCTAssertFalse(fixture.contains("Dynamic Wallpaper 0.3.0"))
        }
        try await fixture.model.shutdownAndWait()
    }

    func testAboutRejectsMissingVersionInsteadOfInventingOne() throws {
        var info = try ProductMetadataTestSupport.information()
        info.removeValue(forKey: "CFBundleShortVersionString")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try ProductMetadataTestSupport.makeBundle(in: directory, information: info)
        XCTAssertThrowsError(try ProductBundleMetadata(bundle: bundle))
    }
}
