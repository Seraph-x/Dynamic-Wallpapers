import XCTest
import AppKit
@testable import WallpaperApp

@MainActor
final class SelectionAppearanceTests: XCTestCase {
    func testSecondaryActionTextMeetsAAAndRenameRemainsDisabledUntilEdited() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        try await fixture.show(appearance: .aqua)
        let batch = try fixture.element(named: "批量选择", role: .button)
        let rename = try fixture.element(named: "重命名", role: .button)
        XCTAssertEqual(batch.isAccessibilityEnabled?(), true)
        XCTAssertEqual(rename.isAccessibilityEnabled?(), false)
        let image = try await fixture.capture("light-secondary-actions")
        let contrast = try fixture.actionContrast(batch, image: image)
        print("Rendered batch action contrast: \(contrast):1")
        XCTAssertGreaterThanOrEqual(contrast, 4.5, "Enabled secondary action text must meet WCAG AA")
        try fixture.typeName("Evening")
        try await Task.sleep(for: .milliseconds(100))
        let enabledRename = try fixture.element(named: "重命名", role: .button)
        XCTAssertEqual(enabledRename.isAccessibilityEnabled?(), true)
        let renamedImage = try await fixture.capture("light-rename-enabled")
        let renameContrast = try fixture.actionContrast(enabledRename, image: renamedImage)
        print("Rendered rename action contrast: \(renameContrast):1")
        XCTAssertGreaterThanOrEqual(renameContrast, 4.5)
        XCTAssertEqual(enabledRename.accessibilityPerformPress?(), true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.model.library.playlists[0].name, "Evening")
        XCTAssertEqual(try fixture.model.store.load(), fixture.model.library)
        XCTAssertEqual(try fixture.element(named: "重命名", role: .button).isAccessibilityEnabled?(), false)
        try await fixture.show(appearance: .darkAqua)
        let darkImage = try await fixture.capture("dark-secondary-actions")
        let darkBatch = try fixture.element(named: "批量选择", role: .button)
        XCTAssertGreaterThanOrEqual(try fixture.actionContrast(darkBatch, image: darkImage), 4.5)
    }

    func testNativeKeyboardNavigationAndBatchSelectionSurviveRowRecreation() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        try await fixture.show(appearance: .aqua)
        let list = try XCTUnwrap(fixture.tables.last)
        let playlist = fixture.model.library.playlists[0]
        XCTAssertTrue(fixture.window.makeFirstResponder(list))
        try fixture.key("\u{F701}", code: 125)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.model.selectedEntryID, playlist.entries[1].id)
        XCTAssertEqual(fixture.model.selectedMediaID, playlist.entries[1].mediaID)
        XCTAssertEqual(list.selectedRow, 1)
        XCTAssertEqual(list.rowView(atRow: 1, makeIfNecessary: false)?.selectionHighlightStyle,
                       NSTableView.SelectionHighlightStyle.none)
        let selected = try await fixture.capture("keyboard-playlist")
        XCTAssertGreaterThan(try fixture.blueCoverage(of: 1, in: list, image: selected, dark: false), 0.35)
        XCTAssertLessThan(try fixture.blueCoverage(of: 0, in: list, image: selected, dark: false), 0.1)

        let sidebar = try XCTUnwrap(fixture.tables.first)
        XCTAssertTrue(fixture.window.makeFirstResponder(sidebar))
        try fixture.key("\u{F700}", code: 126)
        try await Task.sleep(for: .milliseconds(100))
        // The screen saver row sits between Displays and the first playlist.
        XCTAssertEqual(fixture.model.section, .screenSaver)
        try fixture.key("\u{F700}", code: 126)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.model.section, .displays)
        fixture.model.section = .playlist(playlist.id)
        try await Task.sleep(for: .milliseconds(150))
        let batch = try fixture.element(named: "批量选择", role: .button)
        XCTAssertEqual(batch.accessibilityPerformPress?(), true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.model.batchSelection.isActive)
        let selectAll = try fixture.element(named: "全选当前结果", role: .button)
        XCTAssertEqual(selectAll.accessibilityPerformPress?(), true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.model.batchSelection.ids, Set(playlist.entries.map(\.id)))
        let recreated = try XCTUnwrap(fixture.tables.last)
        XCTAssertEqual(recreated.selectedRow, -1)
        fixture.window.setContentSize(NSSize(width: 1000, height: 650))
        try await Task.sleep(for: .milliseconds(100))
        let batchImage = try await fixture.capture("batch-playlist")
        for row in 0..<2 {
            XCTAssertGreaterThan(try fixture.blueCoverage(of: row, in: recreated, image: batchImage, dark: false), 0.35)
        }
        XCTAssertEqual(fixture.model.library.playlists[0], playlist, "Visual selection must not edit playlist data")
        try await fixture.show(appearance: .darkAqua)
        let darkBatch = try await fixture.capture("dark-batch-playlist-minimum")
        for row in 0..<2 {
            XCTAssertGreaterThan(try fixture.blueCoverage(of: row, in: recreated, image: darkBatch, dark: true), 0.35)
        }
        fixture.model.section = .library
        try await Task.sleep(for: .milliseconds(150))
        _ = try await fixture.capture("dark-library-minimum")
        try await fixture.show(appearance: .aqua)
        XCTAssertEqual(try fixture.element(named: "批量选择", role: .button).accessibilityPerformPress?(), true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try fixture.element(named: "全选当前结果", role: .button).accessibilityPerformPress?(), true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.model.batchSelection.ids, Set(fixture.model.library.media.map(\.id)))
        _ = try await fixture.capture("light-batch-library-minimum")
    }

    func testNativeListsUseSubtleBlueInLightAndDarkWindows() async throws {
        let fixture = try SelectionAppearanceFixture(neutralBackdrop: true)
        defer { fixture.close() }
        for (name, appearance, dark) in [("light", NSAppearance.Name.aqua, false),
                                          ("dark", NSAppearance.Name.darkAqua, true)] {
            try await fixture.show(appearance: appearance)
            let tables = fixture.tables
            XCTAssertEqual(tables.count, 2, "The actual sidebar and playlist must remain native lists")
            let sidebar = try XCTUnwrap(tables.first)
            let playlist = try XCTUnwrap(tables.last)
            for (focusedName, focusedTable) in [("sidebar", sidebar), ("playlist", playlist)] {
                XCTAssertTrue(fixture.window.makeFirstResponder(focusedTable))
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertTrue(fixture.window.isKeyWindow)
                XCTAssertTrue(NSApplication.shared.isActive)
                let active = try await fixture.capture("\(name)-\(focusedName)-focused")
                for table in tables {
                    XCTAssertGreaterThanOrEqual(table.selectedRow, 0)
                    XCTAssertEqual(table.rowView(atRow: table.selectedRow, makeIfNecessary: false)?.selectionHighlightStyle,
                                   NSTableView.SelectionHighlightStyle.none)
                    let coverage = try fixture.blueCoverage(of: table.selectedRow, in: table, image: active, dark: dark)
                    XCTAssertGreaterThan(coverage, 0.35, "\(name) focused \(focusedName) must retain subtle blue selection")
                }
            }
            fixture.unfocus()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(fixture.window.isKeyWindow)
            let inactive = try await fixture.capture("\(name)-inactive")
            for (label, table) in [("sidebar", sidebar), ("playlist", playlist)] {
                let coverage = try fixture.blueCoverage(of: table.selectedRow, in: table, image: inactive, dark: dark)
                XCTAssertGreaterThan(coverage, 0.35, "\(name) inactive \(label) must retain blue selection, measured \(coverage)")
            }
        }
    }
}
