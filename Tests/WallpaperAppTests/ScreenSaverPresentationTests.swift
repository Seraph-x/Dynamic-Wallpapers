import AppKit
import SwiftUI
import XCTest
@testable import WallpaperApp

@MainActor
final class ScreenSaverPresentationTests: XCTestCase {
    func testPublishedPreviewControlsAreCenteredSymmetricallyBelowThePreview() async throws {
        let fixture = try SettingsPresentationFixture(content: {
            AnyView(LibraryView(model: $0, product: ProductMetadataTestSupport.product)) })
        defer { fixture.close() }
        fixture.model.section = .screenSaver
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        fixture.window.setFrame(CGRect(x: visible.minX + 40, y: visible.minY + 40,
                                       width: min(1400, visible.width - 80),
                                       height: min(900, visible.height - 80)), display: false)

        try await fixture.show(readyText: "屏保未发布")
        let screenSaver = try XCTUnwrap(fixture.model.screenSaver)
        let surface = screenSaver.preview.view
        let window = try XCTUnwrap(surface.window)
        let surfaceFrame = window.convertToScreen(surface.convert(surface.bounds, to: nil))
        let startFrame = try XCTUnwrap(
            fixture.element("预览已发布版本", role: .button).accessibilityFrame?()
        )
        let stopFrame = try XCTUnwrap(
            fixture.element("停止预览", role: .button).accessibilityFrame?()
        )

        XCTAssertEqual(startFrame.width, stopFrame.width, accuracy: 2,
                       "两个预览操作应占据相同宽度")
        XCTAssertEqual((startFrame.midX + stopFrame.midX) / 2, surfaceFrame.midX, accuracy: 2,
                       "两个预览操作应关于预览画面中心对称")
        XCTAssertGreaterThan(surfaceFrame.minY, max(startFrame.maxY, stopFrame.maxY),
                             "预览操作应位于预览画面正下方")
        XCTAssertLessThan(surfaceFrame.minY - max(startFrame.maxY, stopFrame.maxY), 24,
                          "预览操作不应与预览画面相隔过远")
        try await fixture.model.shutdownAndWait()
    }

    func testScreenSaverManagementRendersScreenshotEvidence() async throws {
        let fixture = try SettingsPresentationFixture(content: {
            AnyView(LibraryView(model: $0, product: ProductMetadataTestSupport.product)) })
        defer { fixture.close() }
        fixture.model.section = .screenSaver

        try await fixture.show(readyText: "屏保未发布")
        let compactCapture = try await fixture.capture("screen-saver-management-compact")

        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let frame = CGRect(x: visible.minX + 40, y: visible.minY + 40,
                           width: min(1400, visible.width - 80), height: min(900, visible.height - 80))
        fixture.window.setFrame(frame, display: false)
        try await fixture.settle()
        let wideCapture = try await fixture.capture("screen-saver-management-wide")

        XCTAssertTrue(FileManager.default.fileExists(atPath: compactCapture.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wideCapture.path))
        try await fixture.model.shutdownAndWait()
    }

    func testSidebarShowsIndependentScreenSaverManagementAndPublicationState() async throws {
        let fixture = try SettingsPresentationFixture(content: {
            AnyView(LibraryView(model: $0, product: ProductMetadataTestSupport.product)) })
        defer { fixture.close() }
        fixture.model.section = .screenSaver
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        fixture.window.setFrame(CGRect(x: visible.minX + 40, y: visible.minY + 40,
                                       width: min(1400, visible.width - 80),
                                       height: min(900, visible.height - 80)), display: false)

        try await fixture.show(readyText: "屏保未发布")
        guard !(fixture.window.contentView?.accessibilityChildren() ?? []).isEmpty else {
            throw XCTSkip("系统未提供 SwiftUI 内容可访问性节点；现有设置页测试也受影响。")
        }
        XCTAssertTrue(fixture.contains("屏幕保护"))
        XCTAssertFalse(fixture.contains("独立屏保设置"))
        XCTAssertTrue(fixture.contains("屏保未发布"))
        XCTAssertFalse(fixture.contains("系统播放尚未验证"))
        let source = try fixture.element("屏保来源")
        let preview = try fixture.element("已发布屏保预览")
        let sourceFrame = try XCTUnwrap(source.accessibilityFrame?())
        let previewFrame = try XCTUnwrap(preview.accessibilityFrame?())
        XCTAssertGreaterThan(sourceFrame.minY, previewFrame.maxY,
                             "宽窗口和全屏下，已发布屏保预览仍应位于屏保来源下方")
        try await fixture.model.shutdownAndWait()
    }
}
