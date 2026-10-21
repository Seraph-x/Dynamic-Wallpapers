import XCTest
import AppKit
import WebKit
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class HelpWindowTests: XCTestCase {
    func testAllFivePagesRenderWithOfflineStylesAndLanguageNavigation() async throws {
        let controller = makeController()
        defer { controller.close() }
        XCTAssertFalse(controller.webView.configuration.websiteDataStore.isPersistent)
        for language in AppLanguage.allCases where language != .system {
            let document = try HelpDocument.bundled(language: language)
            controller.open(document, localizer: AppLocalizer(language: language))
            try await waitForPage(controller, language: language)
            let result = try await controller.webView.evaluateJavaScript("""
                ({ links: document.querySelectorAll('a[data-help-language]').length,
                   current: document.querySelector('[aria-current="page"]').getAttribute('data-help-language'),
                   overflow: getComputedStyle(document.querySelector('.table-scroll')).overflowX,
                   images: document.images.length,
                   external: performance.getEntriesByType('resource').filter(r => !r.name.startsWith('file:')).length })
                """)
            let values = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(values["links"] as? Int, 5)
            XCTAssertEqual(values["current"] as? String, language.rawValue)
            XCTAssertEqual(values["overflow"] as? String, "auto", "Bundled CSS must actually load")
            XCTAssertEqual(values["images"] as? Int, 0)
            XCTAssertEqual(values["external"] as? Int, 0)
        }
    }

    func testLanguageSwitchKeepsSectionAndReopeningUsesTheAppLanguage() async throws {
        let controller = makeController()
        defer { controller.close() }
        let english = AppLocalizer(language: .english)
        let document = try HelpDocument.bundled(language: english.language)
        controller.open(document, localizer: english)
        try await waitForPage(controller, language: .english)
        _ = try await controller.webView.evaluateJavaScript("document.querySelector('a[href=\"#settings\"]').click()")
        try await waitUntil {
            try await controller.webView.evaluateJavaScript("document.querySelector('a[data-help-language=\"fr\"]').hash") as? String == "#settings"
        }
        _ = try await controller.webView.evaluateJavaScript("document.querySelector('a[data-help-language=\"fr\"]').click()")
        try await waitForPage(controller, language: .french)
        XCTAssertEqual(controller.webView.url?.fragment, "settings")
        XCTAssertEqual(english.language, .english)
        controller.open(document, localizer: english)
        try await waitForPage(controller, language: .english)
        XCTAssertNil(controller.webView.url?.fragment)
        controller.open(try HelpDocument.bundled(language: .japanese), localizer: AppLocalizer(language: .japanese))
        try await waitForPage(controller, language: .japanese)
    }

    func testMissingPageNavigationReportsFailureRatherThanChangingLanguage() async throws {
        var failures: [Error] = []
        let controller = makeController { error, _ in failures.append(error) }
        defer { controller.close() }
        let original = try HelpDocument.bundled(language: .english)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DynamicWallpaper-HelpNavigation-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: original.root, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("fr/index.html"))
        controller.open(try HelpDocument(language: .english, root: root), localizer: AppLocalizer(language: .english))
        try await waitForPage(controller, language: .english)
        _ = try await controller.webView.evaluateJavaScript("document.querySelector('a[data-help-language=\"fr\"]').click()")
        try await waitUntil { !failures.isEmpty }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue((failures[0] as? WallpaperError)?.diagnostic?.contains("fr/index.html") == true)
        XCTAssertEqual(controller.webView.url?.deletingLastPathComponent().lastPathComponent, "en")
    }

    func testInvalidLanguageMessagesAreReportedWithoutNavigating() async throws {
        var failures: [Error] = []
        let controller = makeController { error, _ in failures.append(error) }
        defer { controller.close() }
        let document = try HelpDocument.bundled(language: .english)
        controller.open(document, localizer: AppLocalizer(language: .english))
        try await waitForPage(controller, language: .english)
        for (index, payload) in ["\"system\"", "\"../fr\"", "null"].enumerated() {
            _ = try await controller.webView.evaluateJavaScript("window.webkit.messageHandlers.helpLanguage.postMessage(\(payload)); null")
            try await waitUntil { failures.count == index + 1 }
            XCTAssertEqual(controller.webView.url, document.url)
        }
    }

    private func makeController(report: (@MainActor (Error, AppLocalizer) -> Void)? = nil) -> HelpWindowController {
        _ = NSApplication.shared
        NSApplication.shared.finishLaunching()
        return HelpWindowController(product: ProductMetadataTestSupport.product,
            reportFailure: report ?? { error, _ in XCTFail("Help navigation failed: \(error)") })
    }

    private func waitForPage(_ controller: HelpWindowController, language: AppLanguage) async throws {
        try await waitUntil {
            guard !controller.webView.isLoading else { return false }
            return try await controller.webView.evaluateJavaScript("document.documentElement.lang") as? String == language.rawValue
        }
    }

    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Help window verification timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
