import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class LocalizationPresentationTests: XCTestCase {
    func testImportSummaryRelocalizesWhileRawDiagnosticsStayUnchanged() async throws {
        let diagnostic = "海岸 100% %@.mov: decoder unavailable"
        let failure = PresentedFailure.importing(savedCount: 2, fileErrors: [diagnostic], saveFailure: nil)
        let fixture = try SettingsPresentationFixture(content: { _ in AnyView(FailureNotice(failure: failure)) })
        defer { fixture.close() }
        try await fixture.show(readyText: "已导入 2 项，1 项未能导入。")

        for (language, summary) in [
            (AppLanguage.english, "Imported: 2. Failed: 1."),
            (.japanese, "2 項目をインポートしました。1 項目をインポートできませんでした。"),
            (.french, "Éléments importés : 2. Échecs : 1."),
            (.spanish, "Elementos importados: 2. Fallidos: 1."),
            (.chinese, "已导入 2 项，1 项未能导入。")
        ] {
            XCTAssertTrue(fixture.model.setLanguage(language))
            try await fixture.settle()
            XCTAssertTrue(fixture.contains(summary), "Import summary did not update: \(language)")
        }
        XCTAssertEqual(failure.diagnostics, diagnostic)
        XCTAssertEqual(failure.summary, "已导入 2 项，1 项未能导入。")
        try await fixture.model.shutdownAndWait()
    }

    func testCompletelyFailedImportUsesLocalizedItemCount() async throws {
        let failure = PresentedFailure.importing(savedCount: 0, fileErrors: ["A.mov", "B.mov"], saveFailure: nil)
        let fixture = try SettingsPresentationFixture(content: { _ in AnyView(FailureNotice(failure: failure)) })
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.setLanguage(.english))
        try await fixture.show(readyText: "Wallpapers not imported: 2.")
        XCTAssertTrue(fixture.contains("Wallpapers not imported: 2."))
        try await fixture.model.shutdownAndWait()
    }
}
