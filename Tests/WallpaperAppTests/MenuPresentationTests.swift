import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class MenuPresentationTests: XCTestCase {
    func testPlaylistMenuUsesShortLocalizedTitleWithoutWebInteractionDescription() async throws {
        let fixture = try SettingsPresentationFixture(content: { model in
            AnyView(VStack { MenuContent(model: model, product: ProductMetadataTestSupport.product) })
        })
        defer { fixture.close() }
        try await fixture.show(readyText: "播放列表")

        for (language, title) in [(AppLanguage.chinese, "播放列表"), (.english, "Playlists"),
                                  (.japanese, "プレイリスト"), (.french, "Listes de lecture"), (.spanish, "Listas de reproducción")] {
            XCTAssertTrue(fixture.model.setLanguage(language))
            try await fixture.settle()
            XCTAssertTrue(fixture.contains(title), "Missing playlist menu: \(language)")
            let l10n = fixture.model.localizer
            XCTAssertTrue(fixture.contains(l10n("网页交互")))
            XCTAssertFalse(fixture.contains(l10n.webInteractionStatus(fixture.model.webInteractionStatus)))
            XCTAssertFalse(fixture.contains("Playlists · Apply to All Displays"))
        }
        try await fixture.model.shutdownAndWait()
    }

    func testMenuPreservesPauseAndResumeActionsAfterPlaybackBarRemoval() async throws {
        let fixture = try SettingsPresentationFixture(content: { model in
            AnyView(VStack { MenuContent(model: model, product: ProductMetadataTestSupport.product) })
        })
        defer { fixture.close() }
        let before = fixture.model.library
        try await fixture.show(readyText: "播放列表")

        XCTAssertEqual(try fixture.element("下一张壁纸", role: .button).isAccessibilityEnabled?(), false)
        for (title, isPaused) in [("暂停播放", true), ("继续播放", false)] {
            XCTAssertNotNil(try fixture.element(title, role: .button).accessibilityPerformPress?())
            try await fixture.settle()
            XCTAssertEqual(fixture.model.userPaused, isPaused)
        }
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertEqual(try fixture.model.store.load(), before)
        try await fixture.model.shutdownAndWait()
    }
}
