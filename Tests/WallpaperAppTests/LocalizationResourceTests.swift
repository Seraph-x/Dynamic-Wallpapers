import Foundation
import ScreenSaverCore
import XCTest
import WallpaperCore
@testable import WallpaperApp

final class LocalizationResourceTests: XCTestCase {
    func testScenePropertyControlsAndFailuresHaveAllTranslations() {
        let messages = ["使用默认值", "默认值", "场景属性", "设置仅保存在本壁纸的素材库记录中，保存后更新正在使用该场景的窗口。",
            "该场景未声明用户属性。", "属性值不可用，请重置或重新载入。", "保存并应用", "重置属性", "重新载入属性",
            "请输入有效的有限数字。", "场景属性操作失败", "请检查属性值或重新载入场景。", "无法读取所选颜色的 RGB 分量。",
            "仅有预设值，缺少属性声明。", "此属性名称不受运行时支持。", "属性声明无效。", "此属性类型尚不受支持。",
            "此属性依赖暂不支持的显示条件。", "场景属性已保存并应用", "设置已保存，实时应用失败"]
        for language in [AppLanguage.chinese, .english, .japanese, .french, .spanish] {
            for message in messages {
                let translated = AppLocalizer(language: language).text(message)
                XCTAssertFalse(translated.isEmpty)
                if language != .chinese { XCTAssertNotEqual(translated, message) }
            }
        }
    }

    func testDurationUnitLabelsAndPlaylistSummaryAreLocalized() {
        let english = AppLocalizer(language: .english)
        XCTAssertEqual(english.text("单位"), "Unit")
        XCTAssertEqual(english("停留 \("1.5") \("m")"), "Display for 1.5 m")
    }

    func testScreenSaverManagementMessagesHaveTranslations() {
        XCTAssertEqual(AppLocalizer(language: .english).text("屏幕保护"), "Screen Saver")
        let messages = [
            "屏幕保护",
            "屏保来源", "选择屏保来源", "来源已删除", "导入屏保素材…", "导入屏保素材",
            "选择屏保素材", "用于屏保", "屏保静音", "立即同步", "网页内容不支持", "扩展播放器素材不支持",
            "清除已发布屏保内容…",
            "清除已发布屏保内容？", "只清除屏保内容", "不会删除素材库、播放列表或桌面壁纸。已在运行的屏保会在结束后释放旧版本。",
            "发布状态", "屏保已发布", "屏保未发布", "已发布屏保预览", "预览已发布版本", "停止预览",
            "系统安装", "安装或更新屏保…", "重新检查安装状态", "安装状态尚未确认", "尚未安装匹配的屏保",
            "找到多个同标识屏保，请检查安装目录", "安装后请在系统设置中自行选中屏保，并在屏保配置中授权下方发布目录。",
            "确认导入的屏保内容", "确认屏保来源", "选择一个屏保来源", "纳入屏保",
            "排除屏保", "原播放列表不会改变。", "发布到屏保", "添加到素材库；导入后确认屏保内容"
        ]
        for language in [AppLanguage.english, .japanese, .french, .spanish] {
            for message in messages {
                XCTAssertNotEqual(AppLocalizer(language: language).text(message), message,
                                  "Missing screen saver translation: \(language)/\(message)")
            }
        }
    }

    func testEveryScreenSaverFailureCodeHasFiveLocalizedSummaries() {
        let id = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let codes: [ScreenSaverFailure.Code] = [
            .unsupportedSchema(schema: "manifest", actualVersion: 9), .emptySource, .noSupportedMedia,
            .confirmationRequired, .missingMedia(id), .sourceMissing(.media(id)),
            .invalidSourceMetadata("海岸.png"), .missingDuration("海岸.mov"), .unsupportedDuration,
            .invalidProjection, .invalidConsent, .invalidPath("/tmp/海岸"), .nonRegularFile("海岸"),
            .sourceChanged("海岸.png"), .copyMismatch("海岸.png"), .integrityMismatch("海岸.png"),
            .unknownGeneration(id), .identityMissing, .identityChanged, .lockBusy,
            .leaseFailure(.release), .transactionConflict(.commit), .publicationFailed,
            .committedThenFailed, .settingsUnavailable, .pointerUnavailable, .resourceReleaseFailed,
            .cancelled(.publish), .applicationClosing(.shutdown), .bundleMetadataInvalid("Test.saver"),
            .bundleExecutableInvalid("Test.saver"), .infoPlistTooLarge("Test.saver"),
            .infoPlistInvalid("Test.saver"), .installationFailed, .previewUnavailable,
            .authorizationRequired, .bookmarkInvalid, .unexpected
        ]
        for language in [AppLanguage.chinese, .english, .japanese, .french, .spanish] {
            let localizer = AppLocalizer(language: language)
            for code in codes {
                let failure = ScreenSaverFailure(code: code)
                let summary = localizer.screenSaverError(failure)
                XCTAssertFalse(summary.isEmpty, "\(language): \(code)")
                XCTAssertFalse(summary.contains("screenSaver.error."), "\(language): \(code)")
                if language != .chinese {
                    XCTAssertNotEqual(summary, failure.localizedDescription, "\(language): \(code)")
                }
            }
        }
    }

    func testScreenSaverReasonsRemainOrderedAndUnknownDiagnosticStaysOutOfSummary() throws {
        let localizer = AppLocalizer(language: .english)
        let name = "海岸 100% %@.png"
        let source = ScreenSaverFailure(code: .sourceChanged(name))
        let unknown = ScreenSaverFailure(capturing: NSError(domain: "Example", code: 17,
            userInfo: [NSLocalizedDescriptionKey: "secret-path=/tmp/fixture"]))
        let failure = ScreenSaverFailure(code: .publicationFailed, reasons: [source, unknown, source])

        let summary = localizer.screenSaverError(failure)

        XCTAssertEqual(summary.components(separatedBy: name).count - 1, 2)
        XCTAssertFalse(summary.contains("secret-path="))
        let first = try XCTUnwrap(summary.range(of: name))
        let middle = try XCTUnwrap(summary.range(of: "Unexpected"))
        let last = try XCTUnwrap(summary.range(of: name, options: .backwards))
        XCTAssertLessThan(first.lowerBound, middle.lowerBound)
        XCTAssertLessThan(middle.upperBound, last.lowerBound)
        XCTAssertEqual(localizer.screenSaverError(ScreenSaverFailure(code: .previewUnavailable)),
                       "No verified screen saver publication is available to preview.")
        XCTAssertEqual(localizer.screenSaverError(ScreenSaverFailure(code: .installationFailed)),
                       "Could not open the screen saver installer or System Settings.")
    }

    func testManagedMediaMessagesHaveTranslations() {
        let messages = [
            "新导入的文件会复制到应用的 Media 目录，网页会复制整个项目；移动或删除原文件不影响副本播放。",
            "素材库管理", "备份并清空素材库…", "备份并清空素材库？",
            "备份并清空", "最近配置备份", "备份文件夹", "在 Finder 中显示备份", "待清理副本：%lld",
            "先备份配置，再移除全部素材、收藏、播放列表和显示器绑定，并删除托管副本；保留设置、原文件和系统底图。配置备份不包含媒体文件。",
            "清理失败会保留记录并在下次启动时重试。", "部分托管副本未能清理；记录已保留，下次启动时重试。",
            "可一次导入多个文件，应用会保存独立副本，原文件保持不变。",
            "选择包含网页与资源的项目目录，再指定 HTML 入口；整个项目将复制到应用目录。",
            "将从素材库和所有播放列表中移除此壁纸，并删除托管副本；原文件不会删除。",
            "将从素材库和所有播放列表中移除所选壁纸，并删除托管副本；原文件不会删除。",
            "转码输出不能保存在应用托管素材目录中，请选择其他目录。",
            "无法完成导入回滚，请检查相关路径。", "素材库配置不存在，无法备份并清空。",
            "请等待导入完成或取消导入后，再清空素材库。", "当前无法清空素材库。"
        ]
        for language in [AppLanguage.english, .japanese, .french, .spanish] {
            for message in messages {
                XCTAssertNotEqual(AppLocalizer(language: language).text(message), message,
                                  "Missing managed media translation: \(language)/\(message)")
            }
        }
    }

    func testManagementWindowMenuBehaviorAndFailureHaveTranslations() {
        let messages = ["关闭后，仅在管理窗口打开时显示 Dock 图标；关闭全部管理窗口后隐藏。",
                        "无法更新应用菜单和 Dock 的显示状态。"]
        for language in [AppLanguage.english, .japanese, .french, .spanish] {
            for message in messages {
                XCTAssertNotEqual(AppLocalizer(language: language).text(message), message)
            }
        }
    }

    func testSystemWallpaperSyncMessagesHaveTranslations() {
        let messages = [
            "同步系统底图", "等待正式壁纸", "正在同步…", "已同步", "同步失败", "重试同步",
            "系统底图同步失败", "系统底图同步失败。", "系统底图尺寸无效。", "系统底图需要本地素材。",
            "已保存的系统底图损坏或尺寸不匹配。", "系统底图截图尺寸与显示器不一致。",
            "素材文件已变化，请重新应用壁纸后再同步系统底图。", "无法编码系统底图。", "无法读取系统底图素材版本。",
            "网页项目目录不可用。", "无法读取网页项目素材版本。", "目标显示器已断开，无法同步系统底图。",
            "正式壁纸尚未完成显示，无法同步系统底图。", "系统底图显示器尺寸无效。",
            "应用正在退出，无法修改系统底图同步。", "素材库无法读取，无法保存系统底图同步设置。"
        ]
        for language in [AppLanguage.english, .japanese, .french, .spanish] {
            for message in messages {
                XCTAssertNotEqual(AppLocalizer(language: language).text(message), message,
                                  "Missing system wallpaper translation: \(language)/\(message)")
            }
        }
    }

    func testInlineValidationAndCompatibilityMessagesHaveTranslations() {
        let messages = [
            "时长必须是有效数字，例如 30 或 12.5。",
            "当前原生播放器不支持此视频编码。",
            "当前原生播放器不支持此视频封装。",
            "当前扩展播放器不支持此视频封装。",
            "请输入以 .mp4 结尾的文件名，不要包含文件夹路径。",
            "已有任务使用这个输出路径，请更名。",
            "请先选择视频并等待检查完成。",
            "应用正在退出，无法开始转码。",
            "部分壁纸未能导入",
            "素材库无法读取，原配置文件未修改。",
            "请至少勾选一项设置。",
            "所选条目中没有视频或网页，无法修改声音。",
            "请先选择要操作的壁纸。",
            "部分所选项已不存在，请重新选择。",
            "播放列表已不存在，请重新选择。",
            "停留时长须大于 0 秒，循环次数须为正整数。",
            "时长过大，请输入较小的数值。",
            "音量必须在 0% 到 100% 之间。",
            "全屏背景无法关闭",
            "无法截取当前壁纸画面。",
            "请在系统设置中检查“辅助功能”和“输入监控”权限。"
        ]
        for language in [AppLanguage.english, .japanese, .french, .spanish] {
            let localizer = AppLocalizer(language: language)
            for message in messages {
                XCTAssertNotEqual(localizer.text(message), message, "Missing translation: \(language)/\(message)")
            }
        }
    }

    func testPermissionPromptAndActionableErrorsHaveTranslations() {
        let messages = ["辅助功能", "输入监控", "网页交互需要授权", "请在系统设置中允许以下权限：",
                        "授权后，请返回菜单再次开启“网页交互”。", "打开辅助功能设置…", "打开输入监控设置…",
                        "网页交互设置未完成", "网页交互设置未完成…", "无法保存网页交互设置。",
                        "缺少所需权限，网页交互已关闭，但无法保存关闭状态。", "无法打开系统隐私设置。",
                        "应用正在退出，无法修改网页交互。", "素材库无法读取，无法保存网页交互设置。",
                        "应用正在退出，无法请求网页交互权限。"]
        for language in [AppLanguage.english, .japanese, .french, .spanish] {
            for message in messages {
                XCTAssertNotEqual(AppLocalizer(language: language).text(message), message,
                                  "Missing permission translation: \(language)/\(message)")
            }
        }
    }

    func testWebInteractionFailuresTranslateTheirReasonWithoutChangingDiagnostics() {
        let localizer = AppLocalizer(language: .english)
        let reason = "请在系统设置中检查“辅助功能”和“输入监控”权限。"
        let diagnostic = "AXIsProcessTrusted=false; source=海岸 100% %@"
        let status = WebInteractionStatus.failure(WallpaperError(reason, diagnostic: diagnostic))
        XCTAssertEqual(localizer.webInteractionStatus(status),
                       "Web interaction unavailable: Check Accessibility and Input Monitoring permissions in System Settings.")
        XCTAssertEqual(status.diagnostics, diagnostic)
        let unknown = WebInteractionStatus.failure(NSError(domain: "InputMonitor", code: 7))
        XCTAssertEqual(localizer.webInteractionStatus(unknown), "Web interaction unavailable: Cannot monitor desktop clicks.")
        XCTAssertTrue(unknown.diagnostics?.contains("InputMonitor") == true)
    }

    func testTranslatorUsesTheSelectedBundleAndPreservesInterpolation() {
        for (language, general) in [(AppLanguage.english, "General"), (.japanese, "一般"),
                                    (.french, "Général"), (.spanish, "General"), (.chinese, "通用")] {
            let l10n = AppLocalizer(language: language)
            XCTAssertEqual(l10n("通用"), general)
            XCTAssertEqual(l10n.text("通用"), general)
            let filename = "海岸 100% %@ 🏖️"
            XCTAssertTrue(l10n("打开 \(filename)").contains(filename))
        }
        let english = AppLocalizer(language: .english)
        XCTAssertEqual(english("已选 \(3) 项"), "Selected: 3")
        XCTAssertEqual(english("预览中 · 音量 \(25)%"), "Previewing · Volume 25%")
        XCTAssertEqual(english("输出尺寸：\(1920) × \(1080) · H.264"), "Output size: 1,920 × 1,080 · H.264")
        XCTAssertEqual(english.playbackStatus("正在播放 · 海岸 100%"), "Playing · 海岸 100%")
    }

    func testSystemEventHelpPointsToTheRemainingMenuBarStatus() {
        XCTAssertTrue(WallpaperCopy.pauseHelp.contains("菜单栏"))
        XCTAssertFalse(WallpaperCopy.pauseHelp.contains("主窗口底部"))
        for language in [AppLanguage.english, .japanese, .french, .spanish] {
            let l10n = AppLocalizer(language: language)
            XCTAssertNotEqual(l10n.text(WallpaperCopy.pauseHelp), WallpaperCopy.pauseHelp)
        }
        XCTAssertTrue(AppLocalizer(language: .english).text(WallpaperCopy.pauseHelp).contains("menu bar"))
    }

    func testAllFiveLanguagesHaveMatchingNonemptyCatalogsAndFormatArguments() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WallpaperApp/Resources")
        let languages = ["zh-Hans", "en", "ja", "fr", "es"]
        let catalogs = try languages.map { language in
            let data = try Data(contentsOf: root.appendingPathComponent("\(language).lproj/Localizable.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let keys = Set(catalogs[0].keys)
        XCTAssertTrue(keys.contains("跟随系统"))
        XCTAssertTrue(keys.contains("语言"))
        let placeholder = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ll)?[df@]"#)
        func arguments(_ text: String) -> [String] {
            placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { String(text[Range($0.range, in: text)!]) }.sorted()
        }
        for (language, catalog) in zip(languages, catalogs) {
            XCTAssertEqual(Set(catalog.keys), keys, language)
            for (key, value) in catalog {
                XCTAssertFalse(value.isEmpty, "Empty translation: \(language)/\(key)")
                let expected = key.hasPrefix("screenSaver.error.") ? catalogs[0][key]! : key
                XCTAssertEqual(arguments(expected), arguments(value), "Format arguments: \(language)/\(key)")
            }
        }
    }
}
