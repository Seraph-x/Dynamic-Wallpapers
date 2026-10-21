import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class PagePresentationTests: XCTestCase {
    func testPageHeadingsKeepSidebarBrandingWithoutOverridingWindowIdentity() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let pages: [(SidebarSection, String)] = [
            (.library, "壁纸"),
            (.favorites, "我的收藏"),
            (.displays, "显示器"),
            (.playlist(fixture.model.library.playlists[0].id), "应用播放列表")
        ]
        for (section, heading) in pages {
            fixture.model.section = section
            try await fixture.show(appearance: .aqua)
            _ = try element(named: heading, in: fixture.window)
            _ = try element(named: "Dynamic Wallpaper", in: fixture.window)
            XCTAssertEqual(fixture.window.title, "Dynamic Wallpaper — selection verification",
                           "Page navigation must not override the window's identity with a second wordmark")
            XCTAssertFalse(descendants(of: fixture.window).contains {
                $0.accessibilityRole?() == .staticText && matches($0, text: "DynamicWallpaper")
            })
        }
    }

    func testFavoritesEmptyStateKeepsInspectorHiddenInBothAppearances() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.model.section = .favorites
        fixture.model.selectedMediaID = nil
        fixture.model.selectedEntryID = nil
        let before = fixture.model.library

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await showMinimumWindow(fixture, appearance: appearance)
            let states = emptyStates(in: fixture.window)
            XCTAssertEqual(states.count, 1, "Only the favorites page should show an empty state")
            XCTAssertFalse(descendants(of: fixture.window).contains {
                $0.accessibilityIdentifier?() == "wallpaper-inspector"
            }, "No detail column should be present without a wallpaper selection")
            let favorites = try state(titled: "还没有收藏的壁纸", in: fixture.window)
            _ = try element(named: "浏览全部壁纸", in: favorites)
            try assertTextFits(in: favorites, window: fixture.window)
            _ = try await fixture.capture("\(name)-empty-favorites-minimum")
        }

        let favorites = try state(titled: "还没有收藏的壁纸", in: fixture.window)
        let browse = try element(named: "浏览全部壁纸", in: favorites)
        XCTAssertEqual(browse.accessibilityPerformPress?(), true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.model.section, .library)
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertEqual(try fixture.model.store.load(), before)
    }

    func testEmptyPlaylistPreservesImportAndAddFromLibraryActions() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        fixture.model.addPlaylist()
        fixture.model.selectedMediaID = nil
        fixture.model.selectedEntryID = nil
        let before = fixture.model.library
        XCTAssertTrue(try XCTUnwrap(fixture.model.selectedPlaylist).entries.isEmpty)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await showMinimumWindow(fixture, appearance: appearance)
            let playlist = try state(titled: "播放列表中还没有壁纸", in: fixture.window)
            let addMenu = try element(named: "从素材库添加", in: playlist)
            _ = try element(named: "导入壁纸", in: playlist)
            XCTAssertEqual(try element(named: "应用播放列表", in: fixture.window).isAccessibilityEnabled?(), false)
            try assertTextFits(in: playlist, window: fixture.window)
            let image = try await fixture.capture("\(name)-empty-playlist-minimum")
            let contrast = try fixture.actionContrast(addMenu, image: image)
            print("Empty-state secondary action contrast (\(name)): \(contrast):1")
            XCTAssertGreaterThanOrEqual(contrast, 4.5,
                                        "The secondary library action must remain readable in both appearances")
        }

        let playlist = try state(titled: "播放列表中还没有壁纸", in: fixture.window)
        let importButton = try element(named: "导入壁纸", in: playlist)
        XCTAssertEqual(importButton.accessibilityPerformPress?(), true)
        XCTAssertTrue(fixture.model.showingImport)
        fixture.model.showingImport = false
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertEqual(try fixture.model.store.load(), before)
    }

    func testEmptyLibraryOffersTheRealImportAction() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.mutate { library in
            library.media = []
            for index in library.playlists.indices { library.playlists[index].entries = [] }
        })
        fixture.model.section = .library
        try await fixture.show(appearance: .aqua)
        let library = try state(titled: "还没有壁纸", in: fixture.window)
        _ = try await fixture.capture("light-empty-library")
        XCTAssertEqual(try element(named: "导入壁纸", in: library).accessibilityPerformPress?(), true)
        XCTAssertTrue(fixture.model.showingImport)
        fixture.model.showingImport = false
        XCTAssertTrue(fixture.model.library.media.isEmpty, "Opening import must not fabricate library content")
    }

    func testSearchEmptyStateClearsOnlyTheQueryInLibraryAndFavorites() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.model.favorite(fixture.model.library.media[0].id)
        fixture.model.selectedMediaID = nil
        fixture.model.selectedEntryID = nil
        let before = fixture.model.library
        for section in [SidebarSection.library, .favorites] {
            fixture.model.section = section
            fixture.model.search = "no-matching-wallpaper"
            try await fixture.show(appearance: .aqua)
            let search = try state(titled: "未找到匹配的壁纸", in: fixture.window)
            XCTAssertEqual(try element(named: "清除搜索", in: search).accessibilityPerformPress?(), true)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(fixture.model.search.isEmpty)
            XCTAssertEqual(fixture.model.section, section)
            XCTAssertFalse(fixture.model.filteredMedia.isEmpty)
            XCTAssertEqual(fixture.model.library, before)
        }
        XCTAssertEqual(try fixture.model.store.load(), before)
    }

    private func emptyStates(in root: AnyObject) -> [AnyObject] {
        descendants(of: root).filter { $0.accessibilityIdentifier?() == "empty-state" }
    }

    private func showMinimumWindow(_ fixture: SelectionAppearanceFixture, appearance: NSAppearance.Name) async throws {
        try await fixture.show(appearance: appearance)
        fixture.window.setContentSize(NSSize(width: 1000, height: 650))
        try await Task.sleep(for: .milliseconds(100))
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        // Let the compositor finish the resize before comparing pixels with accessibility frames.
        try await Task.sleep(for: .milliseconds(250))
        let size = try XCTUnwrap(fixture.window.contentView?.bounds.size)
        XCTAssertEqual(size.width, 1000, accuracy: 1)
        XCTAssertEqual(size.height, 650, accuracy: 1)
    }

    private func state(titled title: String, in root: AnyObject) throws -> AnyObject {
        try XCTUnwrap(emptyStates(in: root).first { state in
            descendants(of: state).contains { matches($0, text: title) }
        }, "Missing EmptyState: \(title)")
    }

    private func element(named text: String, in root: AnyObject) throws -> AnyObject {
        try XCTUnwrap(descendants(of: root).first { matches($0, text: text) }, "Missing accessible text: \(text)")
    }

    private func matches(_ element: AnyObject, text: String) -> Bool {
        let value = element.accessibilityRole?() == .staticText
            ? accessibilityText("accessibilityValue", of: element) : nil
        return accessibilityText("accessibilityLabel", of: element) == text
            || accessibilityText("accessibilityTitle", of: element) == text || value == text
    }

    private func accessibilityText(_ name: String, of element: AnyObject) -> String? {
        let selector = NSSelectorFromString(name)
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        let value = object.perform(selector)?.takeUnretainedValue()
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }

    private func descendants(of element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).flatMap { descendants(of: $0 as AnyObject) }
    }

    private func assertTextFits(in state: AnyObject, window: NSWindow) throws {
        let bounds = try XCTUnwrap(state.accessibilityFrame?()).insetBy(dx: -1, dy: -1)
        for text in descendants(of: state) where text.accessibilityRole?() == .staticText {
            let frame = try XCTUnwrap(text.accessibilityFrame?())
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(bounds.contains(frame), "Empty-state text must fit its container: \(frame), \(bounds)")
            XCTAssertTrue(window.frame.contains(frame), "Empty-state text must remain inside the minimum-size window")
        }
    }
}
