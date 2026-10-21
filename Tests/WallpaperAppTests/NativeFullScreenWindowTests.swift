import AppKit
import XCTest
@testable import WallpaperApp

@MainActor
final class NativeFullScreenWindowTests: XCTestCase {
    func testBridgeInstallsProxyWithoutChangingApplicationPresentationOptions() {
        let app = NSApplication.shared
        let originalOptions = app.presentationOptions
        let delegate = WindowDelegateProbe()
        let window = makeWindow()
        let view = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: false)
        window.delegate = delegate
        defer { window.close() }

        window.contentView = view

        let proxy = window.delegate as? FullScreenWindowDelegateProxy
        XCTAssertNotNil(proxy)
        XCTAssertTrue(proxy?.originalDelegate === delegate)
        XCTAssertEqual(app.presentationOptions, originalOptions)
    }

    func testBridgeRestoresOriginalDelegateOnlyWhileItStillOwnsWindow() {
        let original = WindowDelegateProbe()
        let replacement = WindowDelegateProbe()
        let first = makeWindow()
        let firstView = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: false)
        first.delegate = original
        first.contentView = firstView
        XCTAssertTrue(first.delegate is FullScreenWindowDelegateProxy)

        first.contentView = nil
        XCTAssertTrue(first.delegate === original)
        first.close()

        let second = makeWindow()
        let secondView = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: false)
        second.delegate = original
        second.contentView = secondView
        second.delegate = replacement

        second.contentView = nil
        XCTAssertTrue(second.delegate === replacement)
        second.close()
    }

    func testDetachingBridgeDuringExitRestoresSuppressedWindowChrome() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let original = WindowDelegateProbe()
        let window = makeWindow()
        let toolbar = NSToolbar(identifier: "detached-fullscreen-exit-toolbar")
        let view = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: false)
        window.toolbar = toolbar
        toolbar.isVisible = true
        window.titleVisibility = .visible
        window.delegate = original
        window.contentView = view
        defer { window.close() }
        let proxy = try XCTUnwrap(window.delegate as? FullScreenWindowDelegateProxy)

        _ = proxy.customWindowsToEnterFullScreen(for: window, on: screen)
        proxy.window(window, startCustomAnimationToEnterFullScreenOn: screen, withDuration: 0)
        proxy.windowDidEnterFullScreen(
            Notification(name: NSWindow.didEnterFullScreenNotification, object: window)
        )
        _ = proxy.customWindowsToExitFullScreen(for: window)
        XCTAssertNil(window.toolbar)
        XCTAssertFalse(toolbar.isVisible)

        window.contentView = nil

        XCTAssertTrue(window.toolbar === toolbar)
        XCTAssertTrue(toolbar.isVisible)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertTrue(window.delegate === original)
    }

    func testBridgeReattachesWithoutMutatingDetachedOrUnrelatedWindow() {
        let first = makeWindow()
        let second = makeWindow()
        let unrelated = makeWindow()
        let firstDelegate = WindowDelegateProbe()
        let secondDelegate = WindowDelegateProbe()
        let unrelatedDelegate = WindowDelegateProbe()
        let unrelatedFrame = unrelated.frame
        let unrelatedBehavior = unrelated.collectionBehavior
        let view = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: false)
        first.delegate = firstDelegate
        second.delegate = secondDelegate
        unrelated.delegate = unrelatedDelegate
        defer { first.close(); second.close(); unrelated.close() }

        first.contentView = view
        first.contentView = nil
        second.contentView = view

        XCTAssertTrue(first.delegate === firstDelegate)
        XCTAssertTrue((second.delegate as? FullScreenWindowDelegateProxy)?.originalDelegate === secondDelegate)
        XCTAssertTrue(unrelated.delegate === unrelatedDelegate)
        XCTAssertEqual(unrelated.frame, unrelatedFrame)
        XCTAssertEqual(unrelated.alphaValue, 1)
        XCTAssertEqual(unrelated.collectionBehavior, unrelatedBehavior)
    }

    func testLegacyBridgeOptsInWithoutChangingEitherDockPolicy() throws {
        let app = NSApplication.shared
        let original = app.activationPolicy()
        defer {
            // After AppKit finishes launching, setting the already-current policy can return false.
            if app.activationPolicy() != original { XCTAssertTrue(app.setActivationPolicy(original)) }
            XCTAssertEqual(app.activationPolicy(), original)
        }
        for policy: NSApplication.ActivationPolicy in [.accessory, .regular] {
            if app.activationPolicy() != policy { XCTAssertTrue(app.setActivationPolicy(policy)) }
            let window = makeWindow()
            defer { window.close() }
            window.collectionBehavior = [.fullScreenNone, .participatesInCycle]
            window.contentView = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: true)

            XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
            XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
            XCTAssertTrue(window.collectionBehavior.contains(.participatesInCycle))
            XCTAssertEqual(app.activationPolicy(), policy)
        }
    }

    func testLegacyBridgeRemovesConflictingAuxiliaryFlag() {
        let window = makeWindow()
        defer { window.close() }
        window.collectionBehavior = [.fullScreenAuxiliary, .participatesInCycle]
        window.contentView = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: true)
        XCTAssertEqual(window.collectionBehavior, [.fullScreenPrimary, .participatesInCycle])
    }

    func testLegacyBridgeReappliesAfterSceneUpdatesAndReattachment() async throws {
        let first = makeWindow()
        let second = makeWindow()
        let view = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: true)
        defer { first.close(); second.close() }
        first.contentView = view
        first.contentView = nil
        second.contentView = view
        first.collectionBehavior = .fullScreenNone
        second.collectionBehavior = .fullScreenNone

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        let deadline = ContinuousClock.now + .seconds(1)
        while !second.collectionBehavior.contains(.fullScreenPrimary), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(second.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertEqual(first.collectionBehavior, .fullScreenNone, "Detached windows must not be reconfigured")
    }

    func testLegacyBridgeDoesNotMakeFixedSizeWindowsResizableOrFullScreen() {
        let window = makeWindow(resizable: false)
        defer { window.close() }
        window.collectionBehavior = .fullScreenNone
        window.contentView = NativeFullScreenWindowBridge.WindowView(configuresLegacyBehavior: true)
        XCTAssertEqual(window.collectionBehavior, .fullScreenNone)
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    private func makeWindow(resizable: Bool = true) -> NSWindow {
        let styles: NSWindow.StyleMask = resizable ? [.titled, .closable, .resizable] : [.titled, .closable]
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: styles, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

@MainActor
private final class WindowDelegateProbe: NSObject, NSWindowDelegate {}
