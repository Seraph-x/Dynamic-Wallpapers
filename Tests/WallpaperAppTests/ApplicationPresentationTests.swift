import AppKit
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class ApplicationPresentationTests: XCTestCase {
    func testModelConstructionDoesNotChangeProcessPresentation() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.presentation.history.isEmpty)
        XCTAssertEqual(fixture.presentation.activations, 0)
    }

    func testDockTogglePersistsWithoutChangingWallpaperOrPauseState() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let before = fixture.model.library
        XCTAssertTrue(fixture.model.setShowDockIcon(false))
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
        XCTAssertFalse(try fixture.model.store.load().settings.showDockIcon)
        XCTAssertEqual(fixture.model.library.media, before.media)
        XCTAssertEqual(fixture.model.library.displays, before.displays)
        XCTAssertEqual(fixture.model.library.playlists, before.playlists)
        XCTAssertFalse(fixture.model.isPaused)
        XCTAssertTrue(fixture.model.setShowDockIcon(true))
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertTrue(try fixture.model.store.load().settings.showDockIcon)
    }

    func testStartupRestoresSavedPolicyWithoutActivating() throws {
        let fixture = try PresentationFixture(showDockIcon: false)
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.restoreApplicationPresentation())
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
        XCTAssertEqual(fixture.presentation.activations, 0)
    }

    func testUnchangedForegroundPolicyDoesNotQueueAnotherActivation() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        fixture.presentation.isActive = true

        fixture.model.setManagementWindowsOpen(true)
        XCTAssertTrue(fixture.model.setShowDockIcon(false))

        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertEqual(fixture.presentation.activations, 0,
                       "Saving a background preference must not reactivate an already-regular app")
    }

    func testActualPolicyChangeRestoresActiveApplicationFocus() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        fixture.presentation.isActive = true
        XCTAssertTrue(fixture.model.setShowDockIcon(false))
        XCTAssertEqual(fixture.presentation.activations, 1)

        fixture.model.setManagementWindowsOpen(true)
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertEqual(fixture.presentation.activations, 2)
        fixture.model.setManagementWindowsOpen(false)
        XCTAssertEqual(fixture.presentation.activations, 2, "Closing the last window must not steal focus")
    }

    func testRejectedPolicyDoesNotChangeSavedChoice() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let before = try Data(contentsOf: fixture.model.store.url)
        fixture.presentation.rejectedPolicies = [.accessory]
        XCTAssertFalse(fixture.model.setShowDockIcon(false))
        XCTAssertEqual(try Data(contentsOf: fixture.model.store.url), before)
        XCTAssertTrue(fixture.model.library.settings.showDockIcon)
        XCTAssertNotNil(fixture.model.presentationFailure)
    }

    func testSaveFailureRestoresActualPolicyAndSuccessfulRetryClearsError() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let before = fixture.model.library
        try fixture.blockSave()
        XCTAssertFalse(fixture.model.setShowDockIcon(false))
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertEqual(fixture.model.library, before)
        XCTAssertNotNil(fixture.model.presentationFailure)
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try fixture.model.store.save(before)
        XCTAssertTrue(fixture.model.setShowDockIcon(false))
        XCTAssertNil(fixture.model.presentationFailure)
    }

    func testFailedPolicyRecoveryIsReportedInsteadOfHidden() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try fixture.blockSave()
        fixture.presentation.rejectedPolicies = [.regular]
        XCTAssertFalse(fixture.model.setShowDockIcon(false))
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
        XCTAssertTrue(fixture.model.library.settings.showDockIcon)
        XCTAssertTrue(try XCTUnwrap(fixture.model.presentationFailure?.localizedDescription).contains("恢复"))
    }

    func testShutdownRejectsDockMutation() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        fixture.model.shutdown()
        XCTAssertFalse(fixture.model.setShowDockIcon(false))
        XCTAssertTrue(fixture.presentation.history.isEmpty)
    }

    func testClosingLastWindowCancelsActivationEvenWhenDockRemainsVisible() throws {
        let fixture = try PresentationFixture(showDockIcon: false)
        defer { fixture.close() }
        XCTAssertTrue(fixture.model.restoreApplicationPresentation())
        fixture.presentation.isActive = true
        fixture.model.setManagementWindowsOpen(true)
        XCTAssertTrue(fixture.model.setShowDockIcon(true))
        let cancellations = fixture.presentation.cancellations

        fixture.model.setManagementWindowsOpen(false)

        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertEqual(fixture.presentation.cancellations, cancellations + 1)
    }

    func testOnlyDesktopWindowOptsOutOfApplicationHiding() async throws {
        let desktop = DesktopWindow(screen: try XCTUnwrap(NSScreen.main))
        let ordinary = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        ordinary.isReleasedWhenClosed = false
        defer { ordinary.close(); desktop.shutdown() }
        XCTAssertFalse(desktop.canHide)
        XCTAssertTrue(ordinary.canHide)
        desktop.shutdown()
        try await desktop.waitForClosing()
    }
}

@MainActor
final class TestApplicationPresentation: ApplicationPresenting {
    var activationPolicy: NSApplication.ActivationPolicy = .regular
    var isActive = false
    var rejectedPolicies = Set<NSApplication.ActivationPolicy>()
    private(set) var history: [NSApplication.ActivationPolicy] = []
    private(set) var activations = 0
    private(set) var cancellations = 0
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        history.append(policy)
        guard !rejectedPolicies.contains(policy) else { return false }
        activationPolicy = policy
        return true
    }
    func activate(reportFailure: @escaping (Error) -> Void) { activations += 1 }
    func cancelActivation() { cancellations += 1 }
}

@MainActor
final class PresentationFixture {
    let model: AppModel
    let presentation = TestApplicationPresentation()
    let loginService = TestLoginItemService()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    init(showDockIcon: Bool = true) throws {
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        var library = Library.empty
        library.settings.showDockIcon = showDockIcon
        try store.save(library)
        model = AppModel(store: store, presentation: presentation, loginItems: LoginItemController(service: loginService))
    }
    func blockSave() throws {
        try FileManager.default.removeItem(at: model.store.url)
        try FileManager.default.createDirectory(at: model.store.url, withIntermediateDirectories: false)
    }
    func close() {
        model.shutdown()
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Fixture cleanup: \(error)") }
    }
}
