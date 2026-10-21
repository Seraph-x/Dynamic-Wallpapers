import AppKit
import Carbon
import XCTest
@testable import WallpaperApp

@MainActor
final class ApplicationLaunchTests: XCTestCase {
    func testOnlyOpenApplicationLoginMarkerClassifiesAsLogin() {
        XCTAssertEqual(ApplicationLaunchOrigin(event: event(login: true)), .login)
        XCTAssertEqual(ApplicationLaunchOrigin(event: event(login: false)), .manual)
        XCTAssertEqual(ApplicationLaunchOrigin(event: nil), .manual)
        XCTAssertEqual(ApplicationLaunchOrigin(event: event(login: true, eventID: AEEventID(kAEReopenApplication))), .manual)
    }

    func testTypeCodeLoginMarkerClassifiesAsLogin() {
        let marker = NSAppleEventDescriptor(typeCode: OSType(keyAELaunchedAsLogInItem))
        XCTAssertEqual(marker.descriptorType, DescType(typeType))
        XCTAssertEqual(marker.enumCodeValue, OSType(keyAELaunchedAsLogInItem))
        XCTAssertEqual(ApplicationLaunchOrigin(event: event(login: true, loginMarker: marker)), .login)
        XCTAssertEqual(ApplicationLaunchOrigin(event: event(login: true,
            eventID: AEEventID(kAEReopenApplication), loginMarker: marker)), .manual)
    }

    func testNonLoginTypeCodeRemainsManual() {
        let marker = NSAppleEventDescriptor(typeCode: OSType(keyAELaunchedAsServiceItem))
        XCTAssertEqual(ApplicationLaunchOrigin(event: event(login: true, loginMarker: marker)), .manual)
    }

    func testTypeCodeLoginDoesNotQueueOrOpenManagementUIInEitherDockMode() throws {
        for visible in [false, true] {
            for openerReady in [false, true] {
                let fixture = try PresentationFixture(showDockIcon: visible)
                defer { fixture.close() }
                var opens = 0
                if openerReady { fixture.model.mainWindow.installOpener { opens += 1 } }
                let marker = NSAppleEventDescriptor(typeCode: OSType(keyAELaunchedAsLogInItem))
                fixture.model.finishLaunching(event: event(login: true, loginMarker: marker))
                if !openerReady { fixture.model.mainWindow.installOpener { opens += 1 } }
                XCTAssertEqual(fixture.presentation.activationPolicy, visible ? .regular : .accessory)
                XCTAssertEqual(opens, 0, "Login must not open a window, even after the menu bar becomes ready")
                XCTAssertEqual(fixture.presentation.activations, 0)
            }
        }
    }

    func testLoginRestoresHiddenDockWithoutActivatingManagementUI() throws {
        let fixture = try PresentationFixture(showDockIcon: false)
        defer { fixture.close() }
        var opens = 0
        fixture.model.mainWindow.installOpener { opens += 1 }
        fixture.model.finishLaunching(event: event(login: true))
        XCTAssertEqual(fixture.presentation.activationPolicy, .accessory)
        XCTAssertEqual(fixture.presentation.activations, 0)
        XCTAssertEqual(opens, 0)
    }

    func testManualLaunchExplicitlyOpensLibraryAndActivatesInBothDockModes() throws {
        for visible in [false, true] {
            let fixture = try PresentationFixture(showDockIcon: visible)
            defer { fixture.close() }
            var opens = 0
            fixture.model.mainWindow.installOpener { opens += 1 }
            fixture.model.finishLaunching(event: event(login: false))
            XCTAssertEqual(fixture.presentation.activationPolicy, visible ? .regular : .accessory)
            XCTAssertEqual(opens, 1, "Manual launch must not depend on SwiftUI's remembered window state")
            XCTAssertEqual(fixture.presentation.activations, 1)
        }
    }

    func testLoginPresentationFailureRemainsVisibleWithoutStealingFocus() throws {
        let fixture = try PresentationFixture(showDockIcon: false)
        defer { fixture.close() }
        fixture.presentation.rejectedPolicies = [.accessory]
        fixture.model.finishLaunching(event: event(login: true))
        XCTAssertNotNil(fixture.model.presentationFailure)
        XCTAssertEqual(fixture.presentation.activations, 0)
        XCTAssertFalse(fixture.model.isShuttingDown)
    }

    func testReopenExplicitlyOpensLibraryEvenWhenDesktopWindowCountsAsVisible() throws {
        let fixture = try PresentationFixture(showDockIcon: false)
        defer { fixture.close() }
        var opens = 0
        fixture.model.mainWindow.installOpener {
            XCTAssertEqual(fixture.presentation.activations, 0, "Open the window before activating")
            opens += 1
        }
        let delegate = AppDelegate()
        delegate.model = fixture.model
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(fixture.presentation.activations, 1)
        XCTAssertTrue(fixture.presentation.history.isEmpty)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testReopenBeforeMenuBarIsReadyIsDeliveredOnceWhenItsOpenerArrives() throws {
        let fixture = try PresentationFixture(showDockIcon: false)
        defer { fixture.close() }
        let delegate = AppDelegate()
        delegate.model = fixture.model
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(fixture.presentation.activations, 0)
        var opens = 0
        fixture.model.mainWindow.installOpener { opens += 1 }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(fixture.presentation.activations, 1)
        fixture.model.mainWindow.installOpener { opens += 1 }
        XCTAssertEqual(opens, 1, "Reattaching a label must not reopen the window")
    }

    func testAppActivationRefreshesExternallyChangedLoginState() throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        let delegate = AppDelegate()
        delegate.model = fixture.model
        fixture.loginService.status = .enabled
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(fixture.model.loginItems.status, .enabled)
    }

    func testBundleStartsWithoutForcingADockIconBeforeReadingPreferences() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
    }

    private func event(login: Bool, eventID: AEEventID = AEEventID(kAEOpenApplication),
                       loginMarker: NSAppleEventDescriptor = NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)))
        -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: eventID,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if login {
            event.setParam(loginMarker, forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }
}
