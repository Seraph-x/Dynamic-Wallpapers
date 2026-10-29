import XCTest
import WallpaperCore
@testable import WallpaperApp

final class SystemMediaLocalizationTests: XCTestCase {
    func testMediaScopeConsentStatusesAndArtworkErrorsHaveFiveTranslations() {
        let keys = ["媒体信息与控制", "播放器来源", "关闭媒体集成", "授权播放器", "重试媒体信息", "重试封面", "媒体来源未保存。",
            "播放中的场景可读取并控制所选的已运行播放器，请仅使用你信任的场景。选择来源不会弹出授权提示；请点击“授权播放器”以请求权限。",
            "封面由播放器提供；歌词和封面配色不可用。", "媒体信息已关闭。", "等待场景播放，当前不向场景提供媒体信息。",
            "正在检查所选播放器。", "所选播放器尚未运行。", "需要授权所选播放器的自动化访问。",
            "所选播放器的自动化权限被拒绝。", "所选播放器没有当前媒体。", "所选播放器的媒体信息可用。",
            "媒体信息暂不可用，请查看错误并重试。", "正在读取播放器封面。", "播放器未提供封面。",
            "封面读取失败，播放信息仍可用。", "场景封面显示失败，播放信息仍可用。", "场景媒体操作失败。"]
        for language in [AppLanguage.chinese, .english, .japanese, .french, .spanish] {
            for key in keys {
                let actual = AppLocalizer(language: language).text(key)
                XCTAssertFalse(actual.isEmpty)
                if language != .chinese { XCTAssertNotEqual(actual, key, "Missing \(language): \(key)") }
            }
        }
    }

    func testAutomationPurposeExistsInProductAndEveryLocalizedPermissionResource() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let product = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
        XCTAssertFalse((product["NSAppleEventsUsageDescription"] as? String ?? "").isEmpty)
        for language in ["en", "zh-Hans", "ja", "fr", "es"] {
            let url = root.appendingPathComponent("Sources/WallpaperApp/Resources/\(language).lproj/InfoPlist.strings")
            let strings = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            let purpose = try XCTUnwrap(strings["NSAppleEventsUsageDescription"], "Missing actual \(language) permission purpose")
            XCTAssertFalse(purpose.isEmpty)
        }
    }
}
