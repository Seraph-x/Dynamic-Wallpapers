import AppKit
import AVFoundation
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class InspectorPresentationTests: XCTestCase {
    func testLibraryAndPlaylistHaveTheSameBaseActionsAndExplicitSource() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = fixture.model.library.media[0]
        let playlist = fixture.model.library.playlists[0]
        for (section, source) in [(SidebarSection.library, "来自：全部壁纸"),
                                  (.playlist(playlist.id), "来自：播放列表 \(playlist.name)")] {
            fixture.model.section = section
            if case .playlist = section { fixture.model.selectedEntryID = playlist.entries[0].id }
            else { fixture.model.selectedMediaID = item.id }
            try await fixture.show(appearance: .aqua)
            XCTAssertTrue(contains(source, in: fixture.window))
            for title in ["应用壁纸", "收藏", "加入播放列表", "在 Finder 中显示"] {
                XCTAssertTrue(contains(title, in: fixture.window), "Missing shared action: \(title)")
            }
            XCTAssertFalse(contains("技术详情", in: fixture.window))
            XCTAssertFalse(contains("文件位置：\(item.url.path)", in: fixture.window))
            XCTAssertEqual(contains("停留时长", in: fixture.window), section != .library)
        }
        try await fixture.model.shutdownAndWait()
    }

    func testHealthyNativeVideoDoesNotOfferTranscoding() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = try await addVideo(to: fixture)
        fixture.model.section = .library
        fixture.model.selectedMediaID = item.id
        try await fixture.show(appearance: .aqua)
        try await wait { fixture.model.inspectorMedia.source?.id == item.id && !fixture.model.inspectorMedia.isChecking }
        XCTAssertFalse(contains("转码…", in: fixture.window), "A video kind alone is not a reason to transcode")
        try await fixture.model.shutdownAndWait()
    }

    func testDescriptionsLeaveBodyButGlobalMuteRemainsVisible() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = try await addVideo(to: fixture)
        let playlistID = fixture.model.library.playlists[0].id
        fixture.model.add(item.id, to: playlistID)
        fixture.model.section = .playlist(playlistID)
        fixture.model.selectedEntryID = fixture.model.library.playlists[0].entries.last?.id
        try await fixture.show(appearance: .aqua)
        XCTAssertTrue(contains("全局静音已开启，此项及其预览均静音。", in: fixture.window))
        XCTAssertFalse(contains("仅影响当前播放列表中的此项及其预览，不影响其他播放列表。", in: fixture.window))
        XCTAssertFalse(contains("保持画面比例，裁剪超出显示区域的部分。", in: fixture.window))
        _ = try fixture.element(named: "音量说明", role: .button)
        _ = try fixture.element(named: "显示方式说明", role: .button)
        try await fixture.model.shutdownAndWait()
    }

    func testEmptyPlaylistTargetsRetainAnExplainedDisabledAction() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.mutate { $0.playlists.removeAll() })
        fixture.model.section = .library
        fixture.model.selectedMediaID = fixture.model.library.media[0].id
        try await fixture.show(appearance: .aqua)
        XCTAssertTrue(contains("加入播放列表", in: fixture.window))
        XCTAssertTrue(contains("请先新建播放列表", in: fixture.window))
        try await fixture.model.shutdownAndWait()
    }

    func testConfirmedIncompatibilityShowsTheActionAndReasonInBothContexts() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let source = fixture.output.appendingPathComponent("unsupported-ffv1.mov")
        try await TranscodeTestFixtures.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10",
            "-t", "0.5", "-c:v", "ffv1", "-strict", "experimental", source.path])
        let item = MediaItem(url: source, kind: .video, width: 64, height: 64, duration: 0.5)
        XCTAssertTrue(fixture.model.mutate { $0.media.append(item) })
        let playlistID = fixture.model.library.playlists[0].id
        fixture.model.add(item.id, to: playlistID)
        for section in [SidebarSection.library, .playlist(playlistID)] {
            fixture.model.section = section
            if case .playlist = section { fixture.model.selectedEntryID = fixture.model.library.playlists[0].entries.last?.id }
            else { fixture.model.selectedMediaID = item.id }
            try await fixture.show(appearance: .aqua)
            try await wait {
                fixture.model.inspectorMedia.source?.id == item.id && !fixture.model.inspectorMedia.isChecking
                    && self.contains("转码…", in: fixture.window)
            }
            XCTAssertNil(fixture.model.inspectorMedia.errorMessage)
            XCTAssertTrue(contains("当前原生播放器不支持此视频编码。", in: fixture.window))
            XCTAssertTrue(contains("转为兼容性更好的 H.264 MP4", in: fixture.window))
            XCTAssertEqual(try fixture.element(named: "转码…", role: .button).isAccessibilityEnabled?(), true)
        }
        _ = try await fixture.capture("inspector-confirmed-transcode")
        XCTAssertTrue(fixture.model.transcoding.queue.jobs.isEmpty, "Diagnosis must not start a transcode")
        try await fixture.model.shutdownAndWait()
    }

    func testOfflineMediaShowsAnErrorAndRealRetryRatherThanTranscoding() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let source = fixture.output.appendingPathComponent("offline.mov")
        let item = MediaItem(url: source, kind: .video, width: 64, height: 64)
        XCTAssertTrue(fixture.model.mutate { $0.media.append(item) })
        fixture.model.section = .library
        fixture.model.selectedMediaID = item.id
        try await fixture.show(appearance: .aqua)
        try await wait {
            fixture.model.inspectorMedia.errorMessage != nil && self.contains("重新检查", in: fixture.window)
        }
        XCTAssertFalse(contains("转码…", in: fixture.window))
        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).isAccessibilityEnabled?(), false)
        let generated = try await VideoIntegrationTests.makeVideo()
        try FileManager.default.moveItem(at: generated, to: source)
        XCTAssertEqual(try fixture.element(named: "重新检查", role: .button).accessibilityPerformPress?(), true)
        // Model publication precedes SwiftUI's accessibility-tree update.
        try await wait {
            fixture.model.inspectorMedia.image != nil && !fixture.model.inspectorMedia.isChecking
                && self.hasEnabledButton("播放预览", in: fixture.window)
        }
        XCTAssertNil(fixture.model.inspectorMedia.errorMessage)
        XCTAssertFalse(contains("转码…", in: fixture.window))
        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).isAccessibilityEnabled?(), true)
        try await fixture.model.shutdownAndWait()
    }

    func testSharedActionsPrecedeEntrySettingsAndSourceFitsBothAppearances() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = try await addVideo(to: fixture)
        var playlist = fixture.model.library.playlists[0]
        playlist.name = "Wlop"
        playlist.entries.append(PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.4)))
        fixture.model.updatePlaylist(playlist)
        fixture.model.section = .playlist(playlist.id)
        fixture.model.selectedEntryID = playlist.entries.last?.id
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try await fixture.show(appearance: appearance)
            fixture.window.setContentSize(NSSize(width: 1000, height: 650))
            try await Task.sleep(for: .milliseconds(250))
            let showInFinder = try fixture.element(named: "在 Finder 中显示", role: .button)
            let audio = try element("此项声音", in: fixture.window)
            XCTAssertGreaterThan(try XCTUnwrap(showInFinder.accessibilityFrame?()).minY,
                                 try XCTUnwrap(audio.accessibilityFrame?()).maxY)
            let source = try element("来自：播放列表 Wlop", in: fixture.window)
            XCTAssertTrue(fixture.window.frame.contains(try XCTUnwrap(source.accessibilityFrame?())))
            _ = try await fixture.capture("inspector-\(name)-playlist-minimum")
            fixture.model.section = .library
            fixture.model.selectedMediaID = item.id
            try await Task.sleep(for: .milliseconds(150))
            _ = try await fixture.capture("inspector-\(name)-library-minimum")
            fixture.model.section = .playlist(playlist.id)
            fixture.model.selectedEntryID = playlist.entries.last?.id
        }
        try await fixture.model.shutdownAndWait()
    }

    func testRepeatedEntrySelectionRestartsPreviewWithTheCorrectAudio() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = try await addVideo(to: fixture)
        var playlist = fixture.model.library.playlists[0]
        let first = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.25))
        let second = PlaylistEntry(mediaID: item.id, audio: AudioSettings(volume: 0.8))
        playlist.entries = [first, second]
        fixture.model.updatePlaylist(playlist)
        XCTAssertTrue(fixture.model.setGlobalMute(false))
        fixture.model.section = .playlist(playlist.id)
        fixture.model.selectedEntryID = first.id
        try await fixture.show(appearance: .aqua)
        try await wait { !fixture.model.inspectorMedia.isChecking }
        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).accessibilityPerformPress?(), true)
        try await wait {
            fixture.model.previewLifetime.activeSurfaceCount == 1 && self.contains("预览中 · 音量 25%", in: fixture.window)
        }
        fixture.model.selectedEntryID = second.id
        try await wait {
            fixture.model.previewLifetime.activeSurfaceCount == 0 && self.contains("播放预览", in: fixture.window)
                && !self.contains("预览中 · 音量 25%", in: fixture.window)
        }
        XCTAssertFalse(contains("预览中 · 音量 25%", in: fixture.window))
        XCTAssertEqual(try fixture.element(named: "播放预览", role: .button).accessibilityPerformPress?(), true)
        try await wait { self.contains("预览中 · 音量 80%", in: fixture.window) }
        XCTAssertEqual(fixture.model.library.playlists[0].entries, [first, second])
        try await fixture.model.shutdownAndWait()
    }

    private func addVideo(to fixture: SelectionAppearanceFixture) async throws -> MediaItem {
        let generated = try await VideoIntegrationTests.makeVideo()
        let source = fixture.output.appendingPathComponent("Inspector.mov")
        try FileManager.default.moveItem(at: generated, to: source)
        let item = try await MediaProbe.inspect(source)
        XCTAssertTrue(fixture.model.mutate { $0.media.append(item) })
        return item
    }

    private func contains(_ text: String, in root: AnyObject) -> Bool {
        let value = root.accessibilityRole?() == .staticText
            ? AccessibilityTestText.read("accessibilityValue", of: root) : nil
        if AccessibilityTestText.read("accessibilityLabel", of: root) == text
            || AccessibilityTestText.read("accessibilityTitle", of: root) == text || value == text { return true }
        return (root.accessibilityChildren?() ?? []).contains { contains(text, in: $0 as AnyObject) }
    }

    private func element(_ text: String, in root: AnyObject) throws -> AnyObject {
        func find(_ root: AnyObject) -> AnyObject? {
            let value = root.accessibilityRole?() == .staticText
                ? AccessibilityTestText.read("accessibilityValue", of: root) : nil
            if AccessibilityTestText.read("accessibilityLabel", of: root) == text
                || AccessibilityTestText.read("accessibilityTitle", of: root) == text || value == text { return root }
            return (root.accessibilityChildren?() ?? []).lazy.compactMap { find($0 as AnyObject) }.first
        }
        return try XCTUnwrap(find(root), "Missing inspector element: \(text)")
    }

    private func hasEnabledButton(_ title: String, in root: AnyObject) -> Bool {
        if root.accessibilityRole?() == .button,
           AccessibilityTestText.read("accessibilityLabel", of: root) == title
            || AccessibilityTestText.read("accessibilityTitle", of: root) == title {
            return root.isAccessibilityEnabled?() == true
        }
        return (root.accessibilityChildren?() ?? []).contains { hasEnabledButton(title, in: $0 as AnyObject) }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Inspector UI test timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
