import AppKit
import XCTest
@testable import WallpaperApp

@MainActor
final class NativeMenuActivationTests: XCTestCase {
    func testInactivePromotionActivatesDirectlyWithoutDockHandoff() async {
        let fixture = NativeActivationFixture()
        fixture.system.isActive = false
        XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
        fixture.activate()
        await nextMainTurn()
        XCTAssertEqual(fixture.system.activations, 1)
        XCTAssertEqual(fixture.system.dockActivations, 0)
    }

    func testActivePromotionWaitsForDockAndRealDeactivationBeforeReactivating() async {
        let fixture = NativeActivationFixture()
        XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
        fixture.activate()
        fixture.activate()
        await nextMainTurn()
        XCTAssertEqual(fixture.system.dockActivations, 1, "Coalesce repeated window activation requests")
        XCTAssertEqual(fixture.system.activations, 0)

        fixture.system.frontmostPID = fixture.system.dockPID
        fixture.workspaceChanged()
        await nextMainTurn()
        XCTAssertEqual(fixture.system.activations, 0, "A workspace event alone does not finish AppKit deactivation")

        fixture.system.isActive = false
        fixture.applicationChanged(NSApplication.didResignActiveNotification)
        await nextMainTurn()
        XCTAssertEqual(fixture.system.activations, 1)
        fixture.completeActivation()
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testAlreadyRegularApplicationNeverUsesDockHandoff() async {
        let fixture = NativeActivationFixture()
        fixture.system.activationPolicy = .regular
        fixture.activate()
        await nextMainTurn()
        XCTAssertEqual(fixture.system.activations, 1)
        XCTAssertEqual(fixture.system.dockActivations, 0)
    }

    func testUserFocusChangeBeforeQueuedHandoffCancelsIt() async {
        let fixture = NativeActivationFixture()
        XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
        fixture.activate()
        fixture.system.frontmostPID = 99
        fixture.system.isActive = false
        await nextMainTurn()
        XCTAssertEqual(fixture.system.dockActivations, 0)
        XCTAssertEqual(fixture.system.activations, 0)
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testUserSwitchingToAnotherAppDuringHandoffIsNotPulledBack() async {
        let fixture = NativeActivationFixture()
        XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
        fixture.activate()
        await nextMainTurn()
        fixture.system.isActive = false
        fixture.system.frontmostPID = 99
        fixture.applicationChanged(NSApplication.didResignActiveNotification)
        fixture.workspaceChanged()
        await nextMainTurn()
        XCTAssertEqual(fixture.system.activations, 0)
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testUserActivationEventIsNotLostWhenDockBecomesFrontmostBeforeQueuedWork() async {
        let fixture = NativeActivationFixture()
        XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
        fixture.activate()
        await nextMainTurn()
        fixture.system.isActive = false
        // The event records the user's choice even if the earlier Dock request has since completed.
        fixture.system.frontmostPID = fixture.system.dockPID
        fixture.workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification,
            object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        fixture.applicationChanged(NSApplication.didResignActiveNotification)
        await nextMainTurn()
        XCTAssertEqual(fixture.system.activations, 0)
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testBackgroundPolicyCancelsQueuedAndInFlightHandoffs() async {
        for started in [false, true] {
            let fixture = NativeActivationFixture()
            XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
            fixture.activate()
            if started { await nextMainTurn() }
            XCTAssertTrue(fixture.presentation.setActivationPolicy(.accessory))
            fixture.system.isActive = false
            fixture.system.frontmostPID = fixture.system.dockPID
            fixture.workspaceChanged()
            fixture.applicationChanged(NSApplication.didResignActiveNotification)
            await nextMainTurn()
            XCTAssertEqual(fixture.system.dockActivations, started ? 1 : 0)
            XCTAssertEqual(fixture.system.activations, 0)
        }
    }

    func testExplicitCancellationPreventsActivationAfterShutdown() async {
        for started in [false, true] {
            let fixture = NativeActivationFixture()
            XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
            fixture.activate()
            if started { await nextMainTurn() }
            fixture.presentation.cancelActivation()
            fixture.system.isActive = false
            fixture.system.frontmostPID = fixture.system.dockPID
            fixture.applicationChanged(NSApplication.didResignActiveNotification)
            await nextMainTurn()
            XCTAssertEqual(fixture.system.dockActivations, started ? 1 : 0)
            XCTAssertEqual(fixture.system.activations, 0)
        }
    }

    func testHidingApplicationCancelsPendingActivation() async {
        let fixture = NativeActivationFixture()
        XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
        fixture.activate()
        await nextMainTurn()
        fixture.applicationChanged(NSApplication.willHideNotification)
        fixture.system.isActive = false
        fixture.system.frontmostPID = fixture.system.dockPID
        fixture.applicationChanged(NSApplication.didResignActiveNotification)
        await nextMainTurn()
        XCTAssertEqual(fixture.system.activations, 0)
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testUnavailableOrRejectingDockReportsFailure() async {
        for missing in [false, true] {
            let fixture = NativeActivationFixture()
            if missing { fixture.system.dockPID = nil }
            else { fixture.system.acceptDockActivation = false }
            XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
            fixture.activate()
            await nextMainTurn()
            XCTAssertEqual(fixture.errors.count, 1)
            XCTAssertEqual(fixture.system.activations, 0)
        }
    }

    func testFailedHandoffCanBeRetriedForTheSameOpenWindow() async {
        for timedOut in [false, true] {
            let fixture = NativeActivationFixture(timeout: 0.02)
            let failed = expectation(description: "First handoff failed")
            fixture.onFailure = { failed.fulfill() }
            fixture.system.acceptDockActivation = timedOut
            XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
            fixture.activate()
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertEqual(fixture.errors.count, 1)
            fixture.onFailure = nil
            fixture.system.acceptDockActivation = true

            fixture.activate()
            await nextMainTurn()
            XCTAssertEqual(fixture.system.dockActivations, 2)
            XCTAssertEqual(fixture.system.activations, 0)
            fixture.system.frontmostPID = fixture.system.dockPID
            fixture.system.isActive = false
            fixture.applicationChanged(NSApplication.didResignActiveNotification)
            await nextMainTurn()
            XCTAssertEqual(fixture.system.activations, 1)
            fixture.completeActivation()
        }
    }

    func testAcceptedDockRequestWithoutAnEventTimesOutExplicitly() async {
        let fixture = NativeActivationFixture(timeout: 0.02)
        let failed = expectation(description: "Dock handoff timeout is surfaced")
        fixture.onFailure = { failed.fulfill() }
        XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
        fixture.activate()
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(fixture.errors.count, 1)
        XCTAssertEqual(fixture.system.activations, 0)
    }

    func testActivationWithoutMenuOwnershipIsNotReportedAsComplete() async {
        let fixture = NativeActivationFixture(timeout: 0.05)
        let failed = expectation(description: "Missing menu ownership is surfaced")
        fixture.onFailure = { failed.fulfill() }
        XCTAssertTrue(fixture.presentation.setActivationPolicy(.regular))
        fixture.activate()
        await nextMainTurn()
        fixture.system.frontmostPID = fixture.system.dockPID
        fixture.system.isActive = false
        fixture.applicationChanged(NSApplication.didResignActiveNotification)
        await nextMainTurn()
        fixture.system.frontmostPID = fixture.system.processID
        fixture.system.isActive = true
        fixture.applicationChanged(NSApplication.didBecomeActiveNotification)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(fixture.errors.count, 1)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class NativeActivationFixture {
    let system = TestNativeApplicationPresentation()
    let notifications = NotificationCenter()
    let workspaceNotifications = NotificationCenter()
    let presentation: SystemApplicationPresentation
    var errors: [Error] = []
    var onFailure: (() -> Void)?

    init(timeout: TimeInterval = 5) {
        presentation = SystemApplicationPresentation(system: system, notifications: notifications,
            workspaceNotifications: workspaceNotifications, handoffTimeout: timeout)
    }

    func activate() {
        presentation.activate { [weak self] error in
            self?.errors.append(error)
            self?.onFailure?()
        }
    }

    func workspaceChanged() {
        workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func applicationChanged(_ name: Notification.Name) { notifications.post(name: name, object: nil) }

    func completeActivation() {
        system.frontmostPID = system.processID
        system.isActive = true
        system.ownsMenuBar = true
        applicationChanged(NSApplication.didBecomeActiveNotification)
    }
}

@MainActor
private final class TestNativeApplicationPresentation: NativeApplicationPresenting {
    var activationPolicy: NSApplication.ActivationPolicy = .accessory
    var isActive = true
    var ownsMenuBar = false
    let processID: pid_t = 1
    var frontmostPID: pid_t? = 1
    var dockPID: pid_t? = 2
    var acceptDockActivation = true
    private(set) var activations = 0
    private(set) var dockActivations = 0

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        activationPolicy = policy
        return true
    }
    func activate() { activations += 1 }
    func activateDock(processID: pid_t) -> Bool {
        dockActivations += 1
        return acceptDockActivation
    }
}
