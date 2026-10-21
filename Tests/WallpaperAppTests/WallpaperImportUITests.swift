import AppKit
import Combine
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class WallpaperImportUITests: XCTestCase {
    func testNativeDefaultActionImportsExplicitEntryAndEmptyEntryIsDisabled() async throws {
        do {
            try await runNativeDefaultActionImport()
        } catch {
            print("IMPORT_UI_UNDERLYING_ERROR: \(String(reflecting: error))")
            throw error
        }
    }

    private func runNativeDefaultActionImport() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("网页 项目")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pages"), withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("\(error)") } }
        try Data("<!doctype html><title>Chosen entry</title>".utf8).write(to: root.appendingPathComponent("pages/scene.html"))
        try Data("<!doctype html><title>Not chosen</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        let model = AppModel(store: store)
        defer { model.shutdown() }
        model.section = .playlist(try XCTUnwrap(model.library.playlists.first?.id))
        let before = model.library
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 520, height: 390),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.title = "DynamicWallpaper — Import verification"
        window.contentView = NSHostingView(rootView: (WallpaperImportView(model: model, projectRoot: root, entry: "")).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(180))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertFalse(window.performKeyEquivalent(with: key), "Empty HTML entry must disable the actual default import action")
        XCTAssertEqual(model.library, before)
        XCTAssertEqual(try store.load(), before)
        let output = TranscodeTestFixtures.root.appendingPathComponent(".build/verification/wallpaper-import-ui/\(UUID())")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await capture(window, to: output.appendingPathComponent("empty-entry.png"))

        window.contentView = NSHostingView(rootView: (WallpaperImportView(model: model,
            projectRoot: root, entry: "pages/scene.html")).environment(\.locale, Locale(identifier: "zh-Hans")))
        try await Task.sleep(for: .milliseconds(180))
        try await capture(window, to: output.appendingPathComponent("selected-entry.png"))
        let imported = expectation(description: "The native default action finishes its asynchronous import")
        var importStates: [Bool] = []
        let importState = model.$importing.dropFirst().prefix(2).collect().sink {
            importStates = $0
            imported.fulfill()
        }
        defer { importState.cancel() }
        XCTAssertTrue(window.performKeyEquivalent(with: key), "The actual default action must import the chosen HTML entry")
        await fulfillment(of: [imported], timeout: 5)
        XCTAssertEqual(importStates, [true, false], "Observe the real import lifecycle, not just a later library value")
        XCTAssertNil(model.errorMessage)
        let item = try XCTUnwrap(model.library.media.first)
        let copiedRoot = model.managedImport.files.directory.appendingPathComponent(item.id.uuidString).appendingPathComponent("Project")
        let project = try XCTUnwrap(item.webProject)
        XCTAssertEqual(project.entry, "pages/scene.html")
        XCTAssertEqual(project.root.path, copiedRoot.path)
        XCTAssertEqual(item.origin?.projectRoot, root.standardizedFileURL)
        XCTAssertEqual(item.origin?.url, root.appendingPathComponent("pages/scene.html").standardizedFileURL)
        XCTAssertEqual(item.url, copiedRoot.appendingPathComponent("pages/scene.html"))
        for path in ["pages/scene.html", "index.html"] {
            XCTAssertEqual(try Data(contentsOf: copiedRoot.appendingPathComponent(path)),
                           try Data(contentsOf: root.appendingPathComponent(path)))
        }
        XCTAssertEqual(model.library.media.count, 1)
        XCTAssertEqual(model.library.playlists[0].entries.map(\.mediaID), [item.id])
        XCTAssertEqual(try store.load(), model.library)

        // A standalone import view dismisses its window; use the separate library
        // window rather than reusing a window whose close animation is in flight.
        let libraryWindow = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 1000, height: 650),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        libraryWindow.isReleasedWhenClosed = false
        defer { libraryWindow.contentView = nil; libraryWindow.close() }
        model.section = .library
        libraryWindow.contentView = NSHostingView(rootView: (LibraryView(model: model,
            product: ProductMetadataTestSupport.product).tint(AppColors.brandAccent)
            .frame(width: 1000, height: 650)).environment(\.locale, Locale(identifier: "zh-Hans")))
        libraryWindow.orderBack(nil)
        try await Task.sleep(for: .milliseconds(200))
        try await capture(libraryWindow, to: output.appendingPathComponent("imported-web-library.png"))
        libraryWindow.contentView = nil
        window.contentView = nil
        try await model.shutdownAndWait()
        print("WALLPAPER_IMPORT_UI scope=rendered-window-and-native-default-button filePickerAndTextInput=unverified artifacts=\(output.path)")
    }

    private func capture(_ window: NSWindow, to url: URL) async throws {
        print("IMPORT_UI_CAPTURE: \(url.lastPathComponent), visible=\(window.isVisible)")
        guard window.isVisible else { throw WallpaperError("The verification window must be visible before capture") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let target = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2); configuration.height = Int(window.frame.height * 2)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
