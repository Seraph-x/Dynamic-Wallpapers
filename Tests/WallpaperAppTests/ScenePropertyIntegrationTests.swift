import AppKit
import SwiftUI
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ScenePropertyIntegrationTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let paths: ApplicationPaths
        let item: MediaItem
        let metadata: Data
        let store: LibraryStore
    }

    func testActualAppModelSaveReopenAndResetPreserveOriginalProject() async throws {
        let fixture = try makeFixture()
        defer { remove(fixture.directory) }
        try await withModel(fixture) { model in
            let editor = model.scenePropertyEditor
            editor.select(fixture.item); await editor.waitForLoading()
            let row = try XCTUnwrap(editor.catalog?.rows.first { $0.name == "caption" })
            editor.setValue(.string("Saved 雪\n\"🎵"), for: row)
            let saved = await editor.save()
            XCTAssertTrue(saved); XCTAssertNil(editor.failure)
            XCTAssertEqual(try fixture.store.load().media.first?.scenePropertyOverrides,
                [.init(name: "caption", value: .string("Saved 雪\n\"🎵"))])
        }
        try await withModel(fixture) { model in
            let item = try XCTUnwrap(model.library.media.first)
            let editor = model.scenePropertyEditor
            editor.select(item); await editor.waitForLoading()
            XCTAssertEqual(editor.values[Data("caption".utf8)], .string("Saved 雪\n\"🎵"))
            let reset = await editor.reset()
            XCTAssertTrue(reset)
            XCTAssertEqual(try fixture.store.load().media.first?.scenePropertyOverrides, [])
        }
        XCTAssertEqual(try Data(contentsOf: fixture.item.sceneProject!.root.appendingPathComponent("project.json")), fixture.metadata)
    }

    func testActualInspectorRejectsInvalidNumberAndSavesTypedInput() async throws {
        let fixture = try makeFixture()
        defer { remove(fixture.directory) }
        var current = fixture.item
        var commits = 0
        let editor = ScenePropertyEditorModel(currentItem: { _ in current }, commit: { _, values in
            var candidate = try fixture.store.load()
            candidate.media[0].scenePropertyOverrides = values
            try fixture.store.save(candidate)
            current = candidate.media[0]; commits += 1
            return current
        }, publish: { _, _, _ in })
        editor.select(current); await editor.waitForLoading()
        XCTAssertEqual(editor.catalog?.rows.count, 5)
        XCTAssertNil(editor.failure)
        _ = NSApplication.shared
        XCTAssertTrue(NSApp.setActivationPolicy(.regular))
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: CGRect(x: 90, y: 90, width: 480, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: InspectorScenePropertiesView(editor: editor)
            .padding(16).environment(\.locale, Locale(identifier: "en")))
        window.contentView = host
        defer { window.orderOut(nil); window.close(); editor.shutdown() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { NSApp.isActive && window.isKeyWindow }
        try await waitUntil { self.elements(window).contains { $0.accessibilityIdentifier?() == "scene-properties" } }
        host.layoutSubtreeIfNeeded()
        let amount = try XCTUnwrap(textFields(host).first { $0.stringValue == "0.25" },
                                   "Actual numeric property field is missing")
        XCTAssertTrue(window.makeFirstResponder(amount))
        let text = try XCTUnwrap(amount.currentEditor() as? NSTextView)
        text.selectAll(nil); text.insertText("not-a-number", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { self.saveButton(window)?.isAccessibilityEnabled?() == false }
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(try fixture.store.load().media[0].scenePropertyOverrides, [])
        text.selectAll(nil); text.insertText("0.75", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { self.saveButton(window)?.isAccessibilityEnabled?() == true }
        XCTAssertEqual(try XCTUnwrap(saveButton(window)).accessibilityPerformPress?(), true)
        try await waitUntil { commits == 1 }
        XCTAssertEqual(try fixture.store.load().media[0].scenePropertyOverrides,
                       [.init(name: "amount", value: .number(0.75))])
        try await waitUntil { editor.status != nil }
        XCTAssertTrue(window.makeFirstResponder(amount))
        let subsequent = try XCTUnwrap(amount.currentEditor() as? NSTextView)
        subsequent.selectAll(nil)
        subsequent.insertText("0.5", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { editor.status == nil }
        print("PROPERTY_UI editClearsStatus=1")
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(try fixture.store.load().media[0].scenePropertyOverrides,
                       [.init(name: "amount", value: .number(0.75))])
        editor.select(current); await editor.waitForLoading()
        try await waitUntil { self.textFields(host).contains { $0.stringValue == "0.75" } }
        XCTAssertEqual(commits, 1)
        let defaults = try XCTUnwrap(elements(window).first {
            $0.accessibilityRole?() == .button
                && AccessibilityTestText.read("accessibilityLabel", of: $0) == "Use default: Amount"
        }, "Each editable property needs an actual default action")
        XCTAssertEqual(defaults.accessibilityPerformPress?(), true)
        try await waitUntil { self.textFields(host).contains { $0.stringValue == "0.25" } }
        XCTAssertEqual(try fixture.store.load().media[0].scenePropertyOverrides,
                       [.init(name: "amount", value: .number(0.75))])
        XCTAssertEqual(try XCTUnwrap(saveButton(window)).accessibilityPerformPress?(), true)
        try await waitUntil { commits == 2 }
        XCTAssertEqual(try fixture.store.load().media[0].scenePropertyOverrides, [])
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for folder in ["Home", "Temp", "Source"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let paths = try ApplicationPaths.resolve(arguments: ["--validation-data-root", directory.path],
            bundleIdentifier: "local.dynamicwallpaper.app.validation.properties", configuredBundleIdentifier: "local.dynamicwallpaper.app",
            environment: ["CFFIXED_USER_HOME": directory.appendingPathComponent("Home").path,
                          "TMPDIR": directory.appendingPathComponent("Temp").path])
        let project = SceneProjectReference(root: directory.appendingPathComponent("Source"), entry: "scene.json", representation: .loose)
        let metadata = Data(#"{"type":"scene","file":"scene.json","future":{"keep":"exact"},"general":{"properties":{"enabled":{"type":"bool","value":true,"text":"Enabled"},"amount":{"type":"slider","value":0.25,"min":0,"max":1,"text":"Amount"},"tint":{"type":"color","value":"0 1 0","text":"Tint"},"caption":{"type":"textinput","value":"Default","text":"Caption"},"mode":{"type":"combo","value":"day","text":"Mode","options":[{"label":"Day","value":"day"},{"label":"Night","value":"night"}]}}}}"#.utf8)
        try metadata.write(to: project.root.appendingPathComponent("project.json"))
        try Data("{}".utf8).write(to: project.entryURL)
        let item = MediaItem(url: project.entryURL, kind: .scene, width: 64, height: 48, backend: .scene, sceneProject: project)
        var library = Library.empty; library.media = [item]
        let store = LibraryStore(url: paths.library)
        try store.save(library)
        return Fixture(directory: directory, paths: paths, item: item, metadata: metadata, store: store)
    }

    private func withModel(_ fixture: Fixture, operation: (AppModel) async throws -> Void) async throws {
        let model = AppModel(paths: fixture.paths, store: fixture.store, setSystemDesktopImage: { _, _ in
            throw WallpaperError("Property persistence must not write a personal system wallpaper")
        })
        var errors: [Error] = []
        do { try await operation(model) } catch { errors.append(error) }
        do { try await model.shutdownAndWait() } catch { errors.append(error) }
        if !errors.isEmpty { throw WallpaperErrorGroup(errors) }
    }

    private func saveButton(_ window: NSWindow) -> AnyObject? {
        elements(window).first {
            $0.accessibilityRole?() == .button && AccessibilityTestText.read("accessibilityLabel", of: $0) == "Save and apply"
        }
    }

    private func elements(_ element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).flatMap { elements($0 as AnyObject) }
    }

    private func textFields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
    }

    private func waitUntil(_ predicate: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while try !predicate() {
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            guard ContinuousClock.now < deadline else {
                print("PROPERTY UI timeout active=\(NSApp.isActive) keyWindow=\(String(describing: NSApp.keyWindow))")
                throw WallpaperError("Actual inspector control did not update")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("Owned fixture cleanup failed: \(error)") }
    }
}
