import AppKit
import XCTest
@testable import WallpaperApp

@MainActor
final class ApplicationMenuLifecycleTests: XCTestCase {
    func testOpeningManagementWindowShowsMenusWithoutChangingSavedDockPreference() async throws {
        let fixture = try MenuLifecycleFixture()
        defer { fixture.close() }
        let saved = try Data(contentsOf: fixture.model.store.url)

        let window = try await fixture.openWindow()

        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertFalse(fixture.model.library.settings.showDockIcon)
        XCTAssertEqual(try Data(contentsOf: fixture.model.store.url), saved)
        window.close()
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
        XCTAssertEqual(try Data(contentsOf: fixture.model.store.url), saved)
    }

    func testOnlyClosingTheLastManagementWindowRestoresHiddenDock() async throws {
        let fixture = try MenuLifecycleFixture()
        defer { fixture.close() }
        let library = try await fixture.openWindow()
        let settings = try await fixture.openWindow()

        library.close()
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        settings.close()
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)

        try await fixture.show(settings)
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular, "A reused window must be tracked again")
        settings.close()
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
    }

    func testHidingOrResigningAWindowIsNotClosingIt() async throws {
        let fixture = try MenuLifecycleFixture()
        defer { fixture.close() }
        let window = try await fixture.openWindow()
        window.resignKey()
        window.orderOut(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        window.close()
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
    }

    func testDockPreferenceAppliesAfterLastWindowCloses() async throws {
        let fixture = try MenuLifecycleFixture(showDockIcon: true)
        defer { fixture.close() }
        let window = try await fixture.openWindow()

        XCTAssertTrue(fixture.model.setShowDockIcon(false))
        XCTAssertFalse(try fixture.model.store.load().settings.showDockIcon)
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        window.close()
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)

        let reopened = try await fixture.openWindow()
        XCTAssertTrue(fixture.model.setShowDockIcon(true))
        reopened.close()
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertTrue(try fixture.model.store.load().settings.showDockIcon)
    }

    func testRejectedForegroundPolicyIsReportedAndReopeningCanRecover() async throws {
        let fixture = try MenuLifecycleFixture()
        defer { fixture.close() }
        fixture.presentation.rejectedPolicies = [.regular]
        let window = try await fixture.openWindow()

        XCTAssertNotNil(fixture.model.presentationFailure)
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
        XCTAssertFalse(try fixture.model.store.load().settings.showDockIcon)
        window.close()
        fixture.presentation.rejectedPolicies = []
        _ = try await fixture.openWindow()
        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertNil(fixture.model.presentationFailure)
    }

    func testRejectedBackgroundPolicyDoesNotChangeSavedPreference() async throws {
        let fixture = try MenuLifecycleFixture()
        defer { fixture.close() }
        let window = try await fixture.openWindow()
        fixture.presentation.rejectedPolicies = [.accessory]
        window.close()

        XCTAssertEqual(fixture.presentation.activationPolicy, .regular)
        XCTAssertNotNil(fixture.model.presentationFailure)
        XCTAssertFalse(try fixture.model.store.load().settings.showDockIcon)
    }

    func testAnUnopenedWindowDoesNotPromoteABackgroundLaunch() throws {
        let fixture = try MenuLifecycleFixture()
        defer { fixture.close() }
        _ = fixture.makeWindow()

        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
        XCTAssertEqual(fixture.presentation.activations, 0)
    }

    func testBorderlessBackgroundWindowDoesNotKeepTheDockVisible() async throws {
        let fixture = try MenuLifecycleFixture()
        defer { fixture.close() }
        let background = fixture.makeWindow(styleMask: .borderless)
        background.orderFront(nil)
        let management = try await fixture.openWindow()
        management.close()

        XCTAssertTrue(background.isVisible)
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
    }
}

@MainActor
private final class MenuLifecycleFixture {
    private let fixture: PresentationFixture
    private let delegate = AppDelegate()
    private var windows: [NSWindow] = []
    var model: AppModel { fixture.model }
    var presentation: TestApplicationPresentation { fixture.presentation }

    init(showDockIcon: Bool = false) throws {
        let application = NSApplication.shared
        if application.activationPolicy() != .regular {
            XCTAssertTrue(application.setActivationPolicy(.regular))
        }
        application.finishLaunching()
        fixture = try PresentationFixture(showDockIcon: showDockIcon)
        delegate.model = model
        // Exercise the real delegate lifecycle without installing a global Quit AppleEvent handler.
        (delegate as NSApplicationDelegate).applicationWillFinishLaunching?(
            Notification(name: NSApplication.willFinishLaunchingNotification, object: application))
        XCTAssertTrue(model.restoreApplicationPresentation())
    }

    func makeWindow(styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 320, height: 200),
                              styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Management menu regression"
        windows.append(window)
        return window
    }

    func openWindow() async throws -> NSWindow {
        let window = makeWindow()
        try await show(window)
        return window
    }

    func show(_ window: NSWindow) async throws {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while !window.isKeyWindow || !NSApplication.shared.isActive {
            while let event = NSApplication.shared.nextEvent(matching: .any, until: .distantPast,
                                                              inMode: .default, dequeue: true) {
                NSApplication.shared.sendEvent(event)
            }
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "MenuLifecycleFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Management window did not become active"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.isMainWindow)
    }

    func close() {
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        windows.forEach { $0.close() }
        fixture.close()
    }
}
