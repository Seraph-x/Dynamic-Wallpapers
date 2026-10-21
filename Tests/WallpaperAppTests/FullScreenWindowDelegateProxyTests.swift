import AppKit
import XCTest
@testable import WallpaperApp

@MainActor
final class FullScreenWindowDelegateProxyTests: XCTestCase {
    func testCustomEnterUsesOnlyTargetWindowAndTargetScreenFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = makeWindow(frame: NSRect(x: 120, y: 140, width: 720, height: 480))
        defer { window.close() }
        let normalFrame = window.frame
        let proxy = FullScreenWindowDelegateProxy(originalDelegate: nil)

        XCTAssertEqual(proxy.customWindowsToEnterFullScreen(for: window, on: screen), [window])
        XCTAssertEqual(proxy.phase, .entering)
        XCTAssertEqual(window.frame, normalFrame)

        proxy.window(window, startCustomAnimationToEnterFullScreenOn: screen, withDuration: 0.25)

        XCTAssertEqual(window.frame, screen.frame)
        XCTAssertEqual(window.alphaValue, 1)
    }

    func testCustomExitUsesOnlyTargetWindowAndRestoresNormalFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = makeWindow(frame: NSRect(x: 90, y: 110, width: 680, height: 440))
        let toolbar = NSToolbar(identifier: "fullscreen-exit-toolbar")
        window.toolbar = toolbar
        toolbar.isVisible = true
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .line
        window.standardWindowButton(.closeButton)?.isHidden = false
        defer { window.close() }
        let normalFrame = window.frame
        let proxy = FullScreenWindowDelegateProxy(originalDelegate: nil)
        _ = proxy.customWindowsToEnterFullScreen(for: window, on: screen)
        proxy.window(window, startCustomAnimationToEnterFullScreenOn: screen, withDuration: 0)
        proxy.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))

        XCTAssertEqual(proxy.customWindowsToExitFullScreen(for: window), [window])
        XCTAssertEqual(proxy.phase, .exiting)
        XCTAssertNil(window.toolbar, "The revealed fullscreen toolbar must be detached from the exit animation")
        XCTAssertFalse(toolbar.isVisible, "The toolbar must retract before the Space starts moving")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isHidden == true)
        proxy.window(window, startCustomAnimationToExitFullScreenWithDuration: 0.25)

        XCTAssertEqual(window.frame, screen.frame,
                       "The window must stay fullscreen while its Space is moving")

        let observation = FullScreenRestorationObservation()
        let token = NotificationCenter.default.addObserver(
            forName: .fullScreenWindowWillRestoreNormalFrame, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                observation.frameBeforeRestore = window.frame
                observation.chromeWasHiddenBeforeRestore = !toolbar.isVisible
                    && window.titleVisibility == .hidden
                    && window.titlebarSeparatorStyle == .none
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        proxy.windowDidExitFullScreen(
            Notification(name: NSWindow.didExitFullScreenNotification, object: window)
        )

        XCTAssertEqual(window.frame, normalFrame)
        XCTAssertEqual(observation.frameBeforeRestore, screen.frame,
                       "Background teardown must be signalled before the normal frame is restored")
        XCTAssertTrue(observation.chromeWasHiddenBeforeRestore)
        XCTAssertTrue(window.toolbar === toolbar, "Exit must restore the original SwiftUI toolbar instance")
        XCTAssertTrue(toolbar.isVisible, "The toolbar must return only at the normal window position")
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.titlebarSeparatorStyle, .line)
        XCTAssertFalse(window.standardWindowButton(.closeButton)?.isHidden == true)
        XCTAssertEqual(window.alphaValue, 1)
    }

    func testCustomExitRetractsToolbarWithoutAppKitImplicitAnimation() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ToolbarAnimationRecordingWindow(
            contentRect: NSRect(x: 90, y: 110, width: 680, height: 440),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        let toolbar = NSToolbar(identifier: "immediate-fullscreen-exit-toolbar")
        window.isReleasedWhenClosed = false
        window.toolbar = toolbar
        toolbar.isVisible = true
        defer { window.close() }
        let proxy = FullScreenWindowDelegateProxy(originalDelegate: nil)
        _ = proxy.customWindowsToEnterFullScreen(for: window, on: screen)
        proxy.window(window, startCustomAnimationToEnterFullScreenOn: screen, withDuration: 0)
        proxy.windowDidEnterFullScreen(
            Notification(name: NSWindow.didEnterFullScreenNotification, object: window)
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.allowsImplicitAnimation = true
            _ = proxy.customWindowsToExitFullScreen(for: window)
        }

        XCTAssertEqual(window.toolbarRemovalAnimationDuration, 0)
        XCTAssertEqual(window.toolbarRemovalAllowedImplicitAnimation, false)
        XCTAssertNil(window.toolbar)
    }

    func testFailuresRestoreMatchingFrameAndPostWindowScopedNotifications() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = makeWindow(frame: NSRect(x: 80, y: 100, width: 640, height: 420))
        let other = makeWindow(frame: NSRect(x: 20, y: 20, width: 320, height: 240))
        defer { window.close(); other.close() }
        let toolbar = NSToolbar(identifier: "failed-fullscreen-exit-toolbar")
        window.toolbar = toolbar
        toolbar.isVisible = true
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .line
        let normalFrame = window.frame
        let proxy = FullScreenWindowDelegateProxy(originalDelegate: nil)
        let failures = FullScreenFailureObservation()
        let center = NotificationCenter.default
        let enterToken = center.addObserver(forName: .fullScreenWindowDidFailToEnter, object: nil, queue: .main) { note in
            let failedID = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if let failedID { failures.enter.append(failedID) }
            }
        }
        let exitToken = center.addObserver(forName: .fullScreenWindowDidFailToExit, object: nil, queue: .main) { note in
            let failedID = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if let failedID { failures.exit.append(failedID) }
            }
        }
        defer { center.removeObserver(enterToken); center.removeObserver(exitToken) }

        _ = proxy.customWindowsToEnterFullScreen(for: window, on: screen)
        window.setFrame(screen.frame, display: false)
        proxy.windowDidFailToEnterFullScreen(window)
        XCTAssertEqual(window.frame, normalFrame)
        XCTAssertEqual(proxy.phase, .idle)
        XCTAssertEqual(failures.enter, [ObjectIdentifier(window)])

        _ = proxy.customWindowsToEnterFullScreen(for: window, on: screen)
        proxy.window(window, startCustomAnimationToEnterFullScreenOn: screen, withDuration: 0)
        proxy.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        _ = proxy.customWindowsToExitFullScreen(for: window)
        XCTAssertNil(window.toolbar)
        XCTAssertFalse(toolbar.isVisible)
        proxy.window(window, startCustomAnimationToExitFullScreenWithDuration: 0)
        proxy.windowDidFailToExitFullScreen(window)
        XCTAssertEqual(window.frame, screen.frame)
        XCTAssertTrue(window.toolbar === toolbar)
        XCTAssertTrue(toolbar.isVisible)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.titlebarSeparatorStyle, .line)
        XCTAssertEqual(proxy.phase, .fullScreen)
        XCTAssertEqual(failures.exit, [ObjectIdentifier(window)])
        XCTAssertFalse(failures.enter.contains(ObjectIdentifier(other)))
        XCTAssertFalse(failures.exit.contains(ObjectIdentifier(other)))
    }

    func testProxyForwardsUnhandledDelegateSelectors() {
        let original = DelegateProbe()
        let proxy = FullScreenWindowDelegateProxy(originalDelegate: original)
        let selector = #selector(NSWindowDelegate.windowShouldClose(_:))

        XCTAssertTrue(proxy.responds(to: selector))
        XCTAssertTrue(proxy.forwardingTarget(for: selector) as AnyObject === original)
    }

    func testAnimationNeverChangesApplicationOrOtherWindow() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let app = NSApplication.shared
        let presentationOptions = app.presentationOptions
        let other = makeWindow(frame: NSRect(x: 30, y: 40, width: 360, height: 260))
        let otherToolbar = NSToolbar(identifier: "unrelated-window-toolbar")
        other.toolbar = otherToolbar
        otherToolbar.isVisible = true
        other.titleVisibility = .visible
        let otherFrame = other.frame
        let otherBehavior = other.collectionBehavior
        let window = makeWindow(frame: NSRect(x: 100, y: 120, width: 700, height: 460))
        defer { window.close(); other.close() }
        let proxy = FullScreenWindowDelegateProxy(originalDelegate: nil)

        _ = proxy.customWindowsToEnterFullScreen(for: window, on: screen)
        proxy.window(window, startCustomAnimationToEnterFullScreenOn: screen, withDuration: 1)
        proxy.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        _ = proxy.customWindowsToExitFullScreen(for: window)
        proxy.window(window, startCustomAnimationToExitFullScreenWithDuration: 1)

        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(other.alphaValue, 1)
        XCTAssertEqual(other.frame, otherFrame)
        XCTAssertEqual(other.collectionBehavior, otherBehavior)
        XCTAssertTrue(other.toolbar === otherToolbar)
        XCTAssertTrue(otherToolbar.isVisible)
        XCTAssertEqual(other.titleVisibility, .visible)
        XCTAssertEqual(app.presentationOptions, presentationOptions)
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

@MainActor
private final class DelegateProbe: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}

@MainActor
private final class FullScreenRestorationObservation {
    var frameBeforeRestore: NSRect?
    var chromeWasHiddenBeforeRestore = false
}

@MainActor
private final class FullScreenFailureObservation {
    var enter: [ObjectIdentifier] = []
    var exit: [ObjectIdentifier] = []
}

@MainActor
private final class ToolbarAnimationRecordingWindow: NSWindow {
    private(set) var toolbarRemovalAnimationDuration: TimeInterval?
    private(set) var toolbarRemovalAllowedImplicitAnimation: Bool?

    override var toolbar: NSToolbar? {
        didSet {
            guard oldValue != nil, toolbar == nil else { return }
            toolbarRemovalAnimationDuration = NSAnimationContext.current.duration
            toolbarRemovalAllowedImplicitAnimation = NSAnimationContext.current.allowsImplicitAnimation
        }
    }
}
