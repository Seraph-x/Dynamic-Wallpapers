import XCTest
import WallpaperCore
@testable import WallpaperApp

final class HelpDocumentTests: XCTestCase {
    func testEveryAppLanguageHasItsOwnBundledPage() throws {
        for language in AppLanguage.allCases where language != .system {
            let document = try HelpDocument.bundled(language: language)
            XCTAssertEqual(document.language, language)
            XCTAssertEqual(document.url.lastPathComponent, "index.html")
            XCTAssertEqual(document.url.deletingLastPathComponent().lastPathComponent, language.rawValue)
            let html = try String(contentsOf: document.url, encoding: .utf8)
            XCTAssertTrue(html.contains("<html lang=\"\(language.rawValue)\">"))
            XCTAssertTrue(html.contains("id=\"troubleshooting\""))
            XCTAssertFalse(html.contains("<img"))
        }
    }

    func testSystemLanguageUsesTheSameResolutionAsTheApplication() throws {
        let root = try HelpDocument.bundled(language: .english).root
        for preferences in [["fr-CA", "en"], ["ja-JP"], ["es-MX"], ["zh-CN"], ["en-GB"], ["de-DE", "es"]] {
            let localizer = AppLocalizer(language: .system, preferredLanguages: preferences)
            let document = try HelpDocument(language: .system, root: root, preferredLanguages: preferences)
            XCTAssertEqual(document.language, localizer.language)
        }
        XCTAssertEqual(try HelpDocument(language: .system, root: root, preferredLanguages: ["de-DE"]).language, .english)
        XCTAssertEqual(try HelpDocument(language: .japanese, root: root, preferredLanguages: ["en"]).language, .japanese)
    }

    func testMissingSelectedTranslationDoesNotOpenEnglish() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("en/index.html", in: root)
        try write("help.css", in: root)
        try write("help.js", in: root)
        XCTAssertNoThrow(try HelpDocument(language: .english, root: root))
        XCTAssertThrowsError(try HelpDocument(language: .french, root: root)) { error in
            XCTAssertEqual((error as? WallpaperError)?.message, "帮助文档文件缺失或无法读取。")
            XCTAssertTrue((error as? WallpaperError)?.diagnostic?.contains("fr/index.html") == true)
        }
    }

    func testEmptyPageAndMissingStylesOrScriptAreErrors() throws {
        for missing in ["en/index.html", "help.css", "help.js"] {
            let root = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for resource in ["en/index.html", "help.css", "help.js"] {
                try write(resource, in: root, contents: resource == missing ? "" : "test resource")
            }
            XCTAssertThrowsError(try HelpDocument(language: .english, root: root), missing)
        }
    }

    func testPackagedAppWithoutResourcesDoesNotUseDevelopmentBundle() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Missing Help.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.dynamicwallpaper.help.missing", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertThrowsError(try HelpDocument.bundled(language: .english, mainBundle: bundle))
    }

    func testPackagedAppReadsAllLanguagesFromItsOwnResourceBundle() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Packaged Help.app")
        let resources = app.appendingPathComponent("Contents/Resources/DynamicWallpaper_WallpaperApp.bundle")
        let help = resources.appendingPathComponent("Help")
        try write("help.css", in: help)
        try write("help.js", in: help)
        let info: [String: Any] = ["CFBundleIdentifier": "test.dynamicwallpaper.help.packaged", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        for language in AppLanguage.allCases where language != .system {
            let contents = "packaged-\(language.rawValue)"
            try write("\(language.rawValue)/index.html", in: help, contents: contents)
            let document = try HelpDocument.bundled(language: language, mainBundle: bundle)
            XCTAssertEqual(document.root, help.standardizedFileURL)
            XCTAssertEqual(try String(contentsOf: document.url, encoding: .utf8), contents)
        }
    }

    func testHelpActionAndErrorsHaveFiveTranslations() {
        let keys = ["帮助文档", "无法打开帮助文档", "帮助文档文件缺失或无法读取。", "帮助内容加载失败，请重新打开帮助文档。"]
        for language in [AppLanguage.english, .japanese, .french, .spanish] {
            for key in keys { XCTAssertNotEqual(AppLocalizer(language: language).text(key), key) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicWallpaper-Help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ relative: String, in root: URL, contents: String = "test resource") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
