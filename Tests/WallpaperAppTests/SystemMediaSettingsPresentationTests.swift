import AppKit
import SwiftUI
import XCTest
import WallpaperCore
import WallpaperMediaIntegration
@testable import WallpaperApp

@MainActor
final class SystemMediaSettingsPresentationTests: XCTestCase {
    func testActualThreeChoicesDoNotReadOrPromptUntilTheExplicitAuthorizationButton() async throws {
        let service = SceneMediaProviderFixture(), controller = SystemMediaController(service: service, pollInterval: 3600)
        let fixture = try makeFixture(controller)
        addTeardownBlock { @MainActor in fixture.close(); try await fixture.model.shutdownAndWait() }
        try await fixture.show(readyText: "关闭媒体集成")
        let radios = fixture.elements.filter { $0.accessibilityRole?() == .radioButton }
        XCTAssertEqual(radios.count, 3)
        XCTAssertEqual(controller.source, .disabled)
        XCTAssertFalse(fixture.contains("授权播放器"))
        try await choose("Music", fixture)
        XCTAssertEqual(controller.source, .music)
        XCTAssertEqual(try fixture.model.store.load().settings.systemMediaSource, .music)
        let selected = await service.reads; XCTAssertTrue(selected.isEmpty)
        XCTAssertNotNil(try fixture.element("授权播放器", role: .button).accessibilityPerformPress?())
        try await waitUntil { await service.reads.count == 1 }
        let authorized = await service.reads; XCTAssertTrue(authorized[0].1)
        XCTAssertNil(controller.snapshot, "Idle explicit consent must not retain metadata")
        XCTAssertEqual(controller.status, .waitingForPlayback)
        try await fixture.settle()
        XCTAssertTrue(fixture.contains("等待场景播放，当前不向场景提供媒体信息。"))
        try await choose("Spotify", fixture)
        let switched = await service.reads; XCTAssertEqual(switched.count, 1)
        XCTAssertEqual(try fixture.model.store.load().settings.systemMediaSource, .spotify)
    }

    func testPermissionProviderNoItemAndFailureStatusesRenderWithExplicitRecovery() async throws {
        let service = SceneMediaProviderFixture(), controller = SystemMediaController(service: service, pollInterval: 3600)
        let fixture = try makeFixture(controller)
        addTeardownBlock { @MainActor in fixture.close(); try await fixture.model.shutdownAndWait() }
        try await fixture.show(readyText: "关闭媒体集成")
        try await choose("Music", fixture)
        await service.setReadResult(.authorizationRequired)
        controller.setPlaying(UUID(), true); await controller.settled(); try await fixture.settle()
        XCTAssertTrue(fixture.contains("需要授权所选播放器的自动化访问。"))
        await service.setReadResult(.authorizationDenied)
        XCTAssertNotNil(try fixture.element("授权播放器", role: .button).accessibilityPerformPress?())
        try await waitUntil { controller.status == .authorizationDenied }; try await fixture.settle()
        XCTAssertTrue(fixture.contains("所选播放器的自动化权限被拒绝。"))
        for (result, status, text) in [
            (SystemMediaReadResult.applicationNotRunning, SystemMediaStatus.applicationNotRunning, "所选播放器尚未运行。"),
            (.noCurrentItem, .noCurrentItem, "所选播放器没有当前媒体。"),
        ] {
            await service.setReadResult(result)
            XCTAssertNotNil(try fixture.element("重试媒体信息", role: .button).accessibilityPerformPress?())
            try await waitUntil { controller.status == status }; try await fixture.settle()
            XCTAssertTrue(fixture.contains(text))
        }
        await service.setReadFailure(.appleEvent(code: -50, message: "Owned read failure"))
        XCTAssertNotNil(try fixture.element("重试媒体信息", role: .button).accessibilityPerformPress?())
        try await waitUntil { controller.status == .failed }; try await fixture.settle()
        XCTAssertTrue(fixture.contains("媒体信息暂不可用，请查看错误并重试。"))
        XCTAssertNotNil(controller.failure)
        let reads = await service.reads
        XCTAssertEqual(reads.map(\.1), [false, true, false, false, false], "Only explicit authorization may request consent")
    }

    func testSourceSaveFailureStaysVisibleAndDoesNotEnableTheProvider() async throws {
        let service = SceneMediaProviderFixture(), controller = SystemMediaController(service: service, pollInterval: 3600)
        let fixture = try makeFixture(controller)
        addTeardownBlock { @MainActor in fixture.close(); try await fixture.model.shutdownAndWait() }
        try await fixture.show(readyText: "关闭媒体集成")
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try FileManager.default.createDirectory(at: fixture.model.store.url, withIntermediateDirectories: false)
        try await choose("Music", fixture)
        XCTAssertEqual(controller.source, .disabled)
        XCTAssertEqual(fixture.model.library.settings.systemMediaSource, .disabled)
        XCTAssertNotNil(fixture.model.failure)
        XCTAssertTrue(fixture.contains("媒体来源未保存。"))
        XCTAssertFalse(fixture.contains("授权播放器"))
        let reads = await service.reads; XCTAssertTrue(reads.isEmpty)
    }

    func testActualArtworkDecoderFailureAndUIRetryKeepMetadataIndependent() async throws {
        let service = SceneMediaProviderFixture(), loader = ArtworkFault()
        let controller = SystemMediaController(service: service, pollInterval: 3600, artworkLoader: loader)
        let fixture = try makeFixture(controller)
        addTeardownBlock { @MainActor in fixture.close(); try await fixture.model.shutdownAndWait() }
        try await fixture.show(readyText: "关闭媒体集成")
        try await choose("Music", fixture)
        controller.setPlaying(UUID(), true); await controller.settled(); await controller.artwork.settled()
        try await fixture.settle()
        XCTAssertTrue(fixture.contains("封面读取失败，播放信息仍可用。"))
        XCTAssertEqual(controller.status, .available); XCTAssertNotNil(controller.snapshot)
        let before = await service.reads.count
        await loader.setInvalid(false)
        XCTAssertNotNil(try fixture.element("重试封面", role: .button).accessibilityPerformPress?())
        try await waitUntil { if case .ready = controller.artwork.state { return true }; return false }
        try await fixture.settle()
        XCTAssertFalse(fixture.contains("封面读取失败，播放信息仍可用。"))
        let after = await service.reads.count; XCTAssertEqual(after, before)
    }

    func testShutdownAndLoadFailureDisableSourceActions() async throws {
        for invalid in [false, true] {
            let service = SceneMediaProviderFixture(), controller = SystemMediaController(service: service, pollInterval: 3600)
            let fixture = try makeFixture(controller, invalidLibrary: invalid)
            addTeardownBlock { @MainActor in fixture.close(); try await fixture.model.shutdownAndWait() }
            try await fixture.showWindow()
            if invalid { XCTAssertTrue(fixture.model.loadFailed) }
            else { try await fixture.model.shutdownAndWait() }
            try await fixture.settle()
            let radios = fixture.elements.filter { $0.accessibilityRole?() == .radioButton }
            XCTAssertEqual(radios.count, 3)
            XCTAssertTrue(radios.allSatisfy { $0.isAccessibilityEnabled?() == false })
            let reads = await service.reads; XCTAssertTrue(reads.isEmpty)
            fixture.close(); try await fixture.model.shutdownAndWait()
        }
    }

    private actor ArtworkFault: SystemMediaArtworkLoading {
        var invalid = true
        func setInvalid(_ value: Bool) { invalid = value }
        func load(_ source: SystemMediaArtworkSource, for identity: SystemMediaArtworkIdentity) async throws -> SystemMediaArtwork {
            try await HTTPSArtworkLoader().load(invalid ? .embedded(Data("invalid owned image".utf8)) : source, for: identity)
        }
    }

    private func makeFixture(_ controller: SystemMediaController, invalidLibrary: Bool = false) throws -> SettingsPresentationFixture {
        try SettingsPresentationFixture(content: { model in
            AnyView(Form { SystemMediaSettingsSection(model: model) }.formStyle(.grouped))
        }, systemMedia: controller, invalidLibrary: invalidLibrary)
    }

    private func choose(_ title: String, _ fixture: SettingsPresentationFixture) async throws {
        XCTAssertNotNil(try fixture.element(title, role: .radioButton).accessibilityPerformPress?())
        try await fixture.settle()
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { XCTFail("Actual media settings action did not settle"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
