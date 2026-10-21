import AppKit
import SwiftUI
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class DirectWallpaperPresentationTests: XCTestCase {
    func testManagementPagesOmitPlaybackBarWithoutChangingDirectWallpaper() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.model.applyMedia(fixture.model.library.media[0], displayID: nil, fit: .fill)
        let before = fixture.model.library
        let playlist = try XCTUnwrap(before.playlists.first)
        for section in [SidebarSection.library, .favorites, .playlist(playlist.id), .displays] {
            fixture.model.section = section
            try await fixture.show(appearance: .aqua)
            XCTAssertFalse(contains("mini-playback-bar", in: fixture.window))
            if section != .displays {
                XCTAssertFalse(contains("暂停播放", in: fixture.window))
                XCTAssertFalse(contains("下一张壁纸", in: fixture.window))
            }
        }
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertEqual(try fixture.model.store.load(), before)
        try await fixture.model.shutdownAndWait()
    }

    func testDisplayCardIdentifiesDirectSourceAndDisablesNext() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = fixture.model.library.media[0]
        fixture.model.applyMedia(item, displayID: nil, fit: .fit)
        fixture.window.contentView = NSHostingView(rootView: (DisplaySettingsView(model: fixture.model)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        XCTAssertTrue(contains("单张壁纸 · \(item.name)", in: fixture.window))
        _ = try fixture.element(named: "应用显示方式", role: .button)
        XCTAssertEqual(try fixture.element(named: "下一张壁纸", role: .button).isAccessibilityEnabled?(), false)
        try await fixture.model.shutdownAndWait()
    }

    func testLibraryAudioDraftIsUsedForPreviewAndDirectApplication() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = try await addVideo(to: fixture)
        XCTAssertTrue(fixture.model.setGlobalMute(false))
        let originalPlaylists = fixture.model.library.playlists
        fixture.model.section = .library
        fixture.model.selectedMediaID = item.id
        try await fixture.show(appearance: .aqua)
        XCTAssertEqual(try fixture.element(named: "此项静音", role: .checkBox).accessibilityPerformPress?(), true)
        try await wait { !fixture.model.inspectorMedia.isChecking }
        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).accessibilityPerformPress?(), true)
        try await wait { self.contains("预览中 · 此项静音", in: fixture.window) }
        XCTAssertEqual(try fixture.element(named: "应用壁纸", role: .button).accessibilityPerformPress?(), true)
        let binding = try XCTUnwrap(fixture.model.library.displays.first)
        XCTAssertEqual(binding.source, .media(item.id, audio: AudioSettings(isMuted: true)))
        XCTAssertEqual(fixture.model.library.playlists, originalPlaylists)
        try await fixture.model.shutdownAndWait()
    }

    func testApplyingFromPlaylistDetailsCopiesItsAudioWithoutEditingThePlaylist() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = try await addVideo(to: fixture)
        var playlist = fixture.model.library.playlists[0]
        let entry = PlaylistEntry(mediaID: item.id, audio: AudioSettings(isMuted: true, volume: 0.4))
        playlist.entries.append(entry)
        fixture.model.updatePlaylist(playlist)
        fixture.model.section = .playlist(playlist.id)
        fixture.model.selectedEntryID = entry.id
        try await fixture.show(appearance: .aqua)
        XCTAssertEqual(try fixture.element(named: "应用壁纸", role: .button).accessibilityPerformPress?(), true)
        XCTAssertEqual(fixture.model.library.displays.first?.source, .media(item.id, audio: entry.audio))
        XCTAssertEqual(fixture.model.library.playlists[0], playlist)
        try await fixture.model.shutdownAndWait()
    }

    func testDisplayAudioEditsAreSavedIndependentlyOfPlaylistEntries() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = try await addVideo(to: fixture)
        fixture.model.applyMedia(item, displayID: nil, fit: .fill, audio: AudioSettings(volume: 0.35))
        let originalPlaylists = fixture.model.library.playlists
        fixture.window.contentView = NSHostingView(rootView: (DisplaySettingsView(model: fixture.model)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        XCTAssertEqual(try fixture.element(named: "此项静音", role: .checkBox).accessibilityPerformPress?(), true)
        XCTAssertTrue(fixture.model.library.displays.allSatisfy {
            $0.source == .media(item.id, audio: AudioSettings(isMuted: true, volume: 0.35))
        })
        XCTAssertEqual(fixture.model.library.playlists, originalPlaylists)
        XCTAssertEqual(try fixture.model.store.load(), fixture.model.library)
        try await fixture.model.shutdownAndWait()
    }

    private func addVideo(to fixture: SelectionAppearanceFixture) async throws -> MediaItem {
        let generated = try await VideoIntegrationTests.makeVideo()
        let url = fixture.output.appendingPathComponent("Direct.mov")
        try FileManager.default.moveItem(at: generated, to: url)
        let item = try await MediaProbe.inspect(url)
        XCTAssertTrue(fixture.model.mutate { $0.media.append(item) })
        return item
    }

    private func contains(_ text: String, in root: AnyObject) -> Bool {
        let value = root.accessibilityRole?() == .staticText
            ? AccessibilityTestText.read("accessibilityValue", of: root) : nil
        if root.accessibilityIdentifier?() == text
            || AccessibilityTestText.read("accessibilityLabel", of: root) == text
            || AccessibilityTestText.read("accessibilityTitle", of: root) == text || value == text { return true }
        return (root.accessibilityChildren?() ?? []).contains { contains(text, in: $0 as AnyObject) }
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Direct wallpaper UI did not reach the expected state") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
