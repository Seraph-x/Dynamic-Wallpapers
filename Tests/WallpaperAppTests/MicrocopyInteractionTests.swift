import AppKit
import SwiftUI
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class MicrocopyInteractionTests: XCTestCase {
    func testPlaybackFailureUsesOneSheet() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.window.contentView = NSHostingView(rootView: FailurePresentationHarness(model: fixture.model)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        fixture.model.report(NSError(domain: "Fixture.Decoder", code: 17,
            userInfo: [NSLocalizedDescriptionKey: "Decoder unavailable"]))
        try await wait { fixture.window.attachedSheet != nil }
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        XCTAssertTrue(fixture.window.attachedSheet === sheet)
        XCTAssertNil(NSApplication.shared.modalWindow, "Diagnostics must not open a second modal alert")
        XCTAssertTrue(try XCTUnwrap(fixture.model.failure?.diagnostics).contains("Decoder unavailable"))
    }

    func testTechnicalDiagnosticsExpandWithoutReplacingTheReadableError() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let failure = PresentedFailure(NSError(domain: "Fixture.Decoder", code: 17,
            userInfo: [NSLocalizedDescriptionKey: "Decoder unavailable"]), context: .preview)
        fixture.window.contentView = NSHostingView(rootView: FailureSheet(failure: failure, dismiss: {})
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        XCTAssertTrue(contains("预览失败。", in: fixture.window))
        let details = try XCTUnwrap(failure.diagnostics)
        XCTAssertFalse(contains(details, in: fixture.window))
        _ = try fixture.element(named: "错误详情", role: .disclosureTriangle).accessibilityPerformPress?()
        try await wait { self.contains(details, in: fixture.window) }
        XCTAssertTrue(contains("预览失败。", in: fixture.window))
        XCTAssertEqual(try fixture.element(named: "复制详情", role: .button).isAccessibilityEnabled?(), true)
        _ = try fixture.element(named: "错误详情", role: .disclosureTriangle).accessibilityPerformPress?()
        try await wait { !self.contains(details, in: fixture.window) }
        try await fixture.model.shutdownAndWait()
    }

    func testSingleWallpaperRemovalWaitsForConfirmationAndPreservesTheFile() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let item = fixture.model.library.media[0]
        let original = fixture.model.library
        let removal = LibraryRemoval.wallpaper(item)
        fixture.window.contentView = NSHostingView(rootView: (RemovalHarness(model: fixture.model, removal: removal)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        _ = try fixture.element(named: "请求移除", role: .button).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet != nil }
        XCTAssertEqual(fixture.model.library, original)
        XCTAssertEqual(try fixture.model.store.load(), original)
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        XCTAssertTrue(contains(removal.message, in: sheet))
        _ = try button("取消", in: sheet).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet == nil }
        XCTAssertEqual(fixture.model.library, original)

        _ = try fixture.element(named: "请求移除", role: .button).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet != nil }
        _ = try button("移除壁纸", in: XCTUnwrap(fixture.window.attachedSheet)).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet == nil }
        XCTAssertFalse(fixture.model.library.media.contains { $0.id == item.id })
        XCTAssertTrue(fixture.model.library.playlists.allSatisfy { $0.entries.allSatisfy { $0.mediaID != item.id } })
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(try fixture.model.store.load(), fixture.model.library)
        try await fixture.model.shutdownAndWait()
    }

    func testPlaylistDeletionExplainsTheDisplayImpactAndKeepsLibraryWallpapers() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let before = fixture.model.library
        let playlist = before.playlists[0]
        let removal = LibraryRemoval.playlist(playlist)
        fixture.window.contentView = NSHostingView(rootView: (RemovalHarness(model: fixture.model, removal: removal)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        _ = try fixture.element(named: "请求移除", role: .button).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet != nil }
        XCTAssertEqual(fixture.model.library, before)
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        XCTAssertTrue(contains(removal.message, in: sheet))
        _ = try button("删除播放列表", in: sheet).accessibilityPerformPress?()
        try await wait { fixture.window.attachedSheet == nil }
        XCTAssertFalse(fixture.model.library.playlists.contains { $0.id == playlist.id })
        XCTAssertEqual(fixture.model.library.media, before.media)
        XCTAssertTrue(before.media.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        XCTAssertEqual(try fixture.model.store.load(), fixture.model.library)
        try await fixture.model.shutdownAndWait()
    }

    func testImportFormatHelpIncludesEverySelectableExtension() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        fixture.window.contentView = NSHostingView(rootView: (WallpaperImportView(model: fixture.model)).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await fixture.show(appearance: .aqua)
        let help = try fixture.element(named: "支持的格式说明", role: .button)
        let message = try XCTUnwrap(help.accessibilityHelp?()).uppercased()
        for fileExtension in MediaProbe.fileExtensions {
            XCTAssertTrue(message.contains(fileExtension.uppercased()), "Missing supported format: \(fileExtension)")
        }
        try await fixture.model.shutdownAndWait()
    }

    private func descendants(of root: AnyObject) -> [AnyObject] {
        [root] + (root.accessibilityChildren?() ?? []).flatMap { descendants(of: $0 as AnyObject) }
    }

    private func contains(_ text: String, in root: AnyObject) -> Bool {
        descendants(of: root).contains {
            $0.accessibilityLabel?() == text || $0.accessibilityTitle?() == text
                || ($0.accessibilityRole?() == .staticText && $0.accessibilityValue?() == text)
        }
    }

    private func button(_ name: String, in root: AnyObject) throws -> AnyObject {
        try XCTUnwrap(descendants(of: root).first {
            $0.accessibilityRole?() == .button && ($0.accessibilityLabel?() == name || $0.accessibilityTitle?() == name)
        }, "Missing confirmation button: \(name)")
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw WallpaperError("Microcopy interaction timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct RemovalHarness: View {
    @ObservedObject var model: AppModel
    let removal: LibraryRemoval
    @State private var pending: LibraryRemoval?
    var body: some View {
        Button("请求移除") { pending = removal }.padding(30)
            .modifier(LibraryRemovalConfirmation(removal: $pending, model: model))
    }
}

private struct FailurePresentationHarness: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Color.clear.applicationFailurePresentation($model.failure)
    }
}
