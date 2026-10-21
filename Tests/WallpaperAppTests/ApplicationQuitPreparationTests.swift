import AppKit
import SwiftUI
import XCTest
import WebWallpaperBridge
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ApplicationQuitPreparationTests: XCTestCase {
    func testQuitCancelsImportSheetWithoutSavingOrStartingImport() async throws {
        let fixture = try SettingsPresentationFixture(content: {
            AnyView(LibraryView(model: $0, product: ProductMetadataTestSupport.product)) })
        defer { fixture.close() }
        try await fixture.show(readyText: "导入壁纸")
        let delegate = AppDelegate()
        defer { _ = delegate }
        let before = fixture.model.library
        fixture.model.showingImport = true
        try await fixture.settle()
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        // Match the hidden sheet that blocked the production Quit AppleEvent.
        fixture.window.orderOut(nil)
        sheet.orderOut(nil)
        XCTAssertNotNil(fixture.window.attachedSheet)
        // The native application posts this before AppKit's modal-sheet termination check.
        NotificationCenter.default.post(name: .DWApplicationWillRequestTermination, object: NSApp)
        XCTAssertNil(fixture.window.attachedSheet, "A hidden import sheet must not block normal quit")
        try await fixture.settle()
        XCTAssertFalse(fixture.model.showingImport)
        XCTAssertFalse(fixture.model.importing)
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertEqual(try fixture.model.store.load(), before)
        fixture.window.makeKeyAndOrderFront(nil)
        try await fixture.settle()
        fixture.model.showingImport = true
        try await fixture.settle()
        XCTAssertNotNil(fixture.window.attachedSheet, "A cancelled quit must not leave a stale presentation binding")
        NotificationCenter.default.post(name: .DWApplicationWillRequestTermination, object: NSApp)
        try await fixture.model.shutdownAndWait()
    }

    func testQuitDiscardsBatchDraftAndCancelsRemovalConfirmation() async throws {
        let fixture = try SelectionAppearanceFixture()
        defer { fixture.close() }
        let delegate = AppDelegate()
        defer { _ = delegate }
        try await fixture.show(appearance: .aqua)
        try await fixture.waitForPlaylistControls()
        let before = fixture.model.library
        for title in ["批量选择", "全选当前结果", "批量编辑…"] {
            XCTAssertEqual(try fixture.element(named: title, role: .button).accessibilityPerformPress?(), true)
            try await Task.sleep(for: .milliseconds(200))
        }
        let sheet = try XCTUnwrap(fixture.window.attachedSheet)
        try await Task.sleep(for: .milliseconds(300))
        sheet.contentView?.layoutSubtreeIfNeeded()
        let timing = try XCTUnwrap(descendants(sheet).first {
            $0.accessibilityIdentifier?() == "batch-change-timing"
        })
        XCTAssertNotNil(timing.accessibilityPerformPress?())
        try await Task.sleep(for: .milliseconds(200))
        NotificationCenter.default.post(name: .DWApplicationWillRequestTermination, object: NSApp)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(fixture.window.attachedSheet)
        XCTAssertEqual(fixture.model.library, before, "Quit must not save an unfinished batch draft")
        XCTAssertEqual(try fixture.element(named: "移除…", role: .button).accessibilityPerformPress?(), true)
        try await Task.sleep(for: .milliseconds(200))
        NotificationCenter.default.post(name: .DWApplicationWillRequestTermination, object: NSApp)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(fixture.window.attachedSheet)
        XCTAssertEqual(fixture.model.library, before, "Quit must cancel destructive confirmations")
        XCTAssertEqual(try fixture.model.store.load(), before)
        try await fixture.model.shutdownAndWait()
    }

    private func descendants(_ root: AnyObject) -> [AnyObject] {
        [root] + (root.accessibilityChildren?() ?? []).flatMap { descendants($0 as AnyObject) }
    }
}
