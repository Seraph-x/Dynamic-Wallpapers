import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor private final class EditorLaunchSpy: EditorLaunchServicing {
    var installed: URL? = URL(fileURLWithPath: "/Applications/Test Editor.app")
    var choice = EditorInstallChoice.cancel
    var lookupCount = 0, downloadCount = 0, promptCount = 0
    var opened: [(URL, URL)] = []
    var failure: Error?
    func installedEditor() -> URL? { lookupCount += 1; return installed }
    func installChoice(localizer: AppLocalizer) -> EditorInstallChoice { promptCount += 1; return choice }
    func downloadEditor() throws { downloadCount += 1 }
    func validateEditor(_ app: URL) throws { if let failure { throw failure } }
    func open(_ url: URL, with app: URL) async throws { if let failure { throw failure }; opened.append((url,app)) }
}

@MainActor final class EditorLauncherTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    private func exchange() throws -> EditorExchange { try EditorExchange(hostBundleIdentifier:"local.dynamicwallpaper.app",scenes:[],renderer:nil) }
    private var localizer: AppLocalizer { AppLocalizer(language: .english) }

    func testConstructionDoesNoLookupDownloadOrFilesystemWork() throws {
        let services = EditorLaunchSpy()
        _ = EditorLauncher(directory:directory,services:services)
        XCTAssertEqual(services.lookupCount,0); XCTAssertEqual(services.downloadCount,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
    func testMissingEditorOnlyPromptsOnExplicitActionAndNeverInstalls() async throws {
        let services = EditorLaunchSpy(); services.installed = nil
        let launcher = EditorLauncher(directory:directory,services:services)
        try await launcher.open(exchange:exchange(),project:nil,localizer:localizer)
        XCTAssertEqual(services.promptCount,1); XCTAssertTrue(services.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
        services.choice = .download
        try await launcher.open(exchange:exchange(),project:nil,localizer:localizer)
        XCTAssertEqual(services.downloadCount,1); XCTAssertTrue(services.opened.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
    func testInstalledEditorOpensWithoutPromptingOrDownloading() async throws {
        let services = EditorLaunchSpy(), launcher = EditorLauncher(directory:directory,services:services)
        services.choice = .download
        let scene = SceneProjectReference(root:URL(fileURLWithPath:"/tmp/场景 A"),entry:"scene.json",representation:.loose)
        try await launcher.open(exchange:exchange(),project:scene,localizer:localizer)
        let first = try XCTUnwrap(services.opened.first)
        guard case .openEditor(let project,let descriptor) = try EditorLink(url:first.0) else { return XCTFail() }
        XCTAssertEqual(project,scene)
        XCTAssertEqual(try EditorExchange(data:Data(contentsOf:XCTUnwrap(descriptor))),try exchange())
        XCTAssertEqual(services.promptCount,0)
        XCTAssertEqual(services.downloadCount,0)
        XCTAssertEqual(first.1,services.installed)
    }
    func testValidationFailureDoesNotPublishOrHideTheError() async throws {
        let services = EditorLaunchSpy(); services.failure = WallpaperError("Invalid application")
        let launcher = EditorLauncher(directory:directory,services:services)
        do { try await launcher.open(exchange:exchange(),project:nil,localizer:localizer); XCTFail() } catch {}
        XCTAssertTrue(services.opened.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
    func testPublisherRejectsRedirectedDirectory() async throws {
        let publisher = EditorExchangePublisher(directory:directory)
        _ = try await publisher.publish(exchange())
        let moved = directory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at:directory,to:moved)
        defer { try? FileManager.default.removeItem(at:moved) }
        try FileManager.default.createSymbolicLink(at:directory,withDestinationURL:moved)
        do { _ = try await publisher.publish(exchange()); XCTFail() } catch {}
    }
}
