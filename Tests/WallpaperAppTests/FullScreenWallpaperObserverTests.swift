import AppKit
import Combine
import XCTest
@testable import WallpaperApp

@MainActor
final class FullScreenWallpaperObserverTests: XCTestCase {
    func testSpaceAndGeometryChangesRecreateMirrorsAndDetachRemovesObservers() async throws {
        _ = NSApplication.shared
        let window = SpaceControlledWindow(contentRect: CGRect(x: 80, y: 80, width: 200, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let state = FullScreenWallpaperState()
        var sessions: [WallpaperMirrorSession] = []
        let observer = FullScreenWallpaperObserver.WindowView(state: state, capture: { _ in image }, makeMirror: { _ in
            let session = WallpaperMirrorSession(source: { nil }, systemWallpaper: { image },
                changes: Empty().eraseToAnyPublisher())
            sessions.append(session)
            return session
        })
        window.contentView?.addSubview(observer)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Initial observer mirror") { state.mirror != nil }
        XCTAssertEqual(sessions.count, 1)
        window.activeSpaceForTest = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await state.waitForCleanup()
        XCTAssertTrue(sessions[0].isClosed)
        XCTAssertNil(state.mirror)
        window.activeSpaceForTest = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Returned Space mirror") { sessions.count == 2 && state.mirror != nil }
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification] {
            let count = sessions.count
            NotificationCenter.default.post(name: name, object: window)
            try await WallpaperMirrorTestSupport.waitUntil(description: "Geometry update mirror") {
                sessions.count == count + 1 && state.mirror != nil
            }
            XCTAssertTrue(sessions[count - 1].isClosed)
        }
        let exitingMirror = state.mirror
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(state.mirror === exitingMirror, "willExit must retain the live mirror")
        XCTAssertFalse(sessions.last?.isClosed == true)

        XCTAssertFalse(exitingMirror?.view.isHidden == true)
        NotificationCenter.default.post(name: .fullScreenWindowWillRestoreNormalFrame, object: window)
        XCTAssertTrue(exitingMirror?.view.isHidden == true,
                      "The live layer must disappear synchronously before the window is resized")
        try await state.waitForCleanup()
        XCTAssertNil(state.mirror,
                     "The fullscreen mirror must be removed before the normal frame is restored")
        XCTAssertTrue(sessions.last?.isClosed == true)

        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try await state.waitForCleanup()
        XCTAssertNil(state.mirror)
        observer.removeFromSuperview()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await state.waitForCleanup()
        XCTAssertEqual(sessions.count, 4)
        XCTAssertTrue(sessions.allSatisfy(\.isClosed))
    }

    func testScreenshotRequestsRunOnlyInTheActiveFullScreenSpace() async throws {
        _ = NSApplication.shared
        let window = SpaceControlledWindow(contentRect: CGRect(x: 80, y: 80, width: 200, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let frame = try WallpaperMirrorTestSupport.sampleBuffer()
        let state = FullScreenWallpaperState()
        var requests = 0
        let observer = FullScreenWallpaperObserver.WindowView(state: state, capture: { _ in image }, makeMirror: { _ in
            WallpaperMirrorSession(source: { WallpaperMirrorSource(window: window) }, systemWallpaper: { image },
                changes: Empty().eraseToAnyPublisher(), makeStream: { _, view in
                    let output = WallpaperMirrorFrameOutput(renderer: view.videoLayer.sampleBufferRenderer)
                    let producer = WallpaperScreenshotProducer(output: output) { requests += 1; return frame }
                    return WallpaperMirrorStream(driver: producer.driver, output: output)
                })
        })
        window.contentView?.addSubview(observer)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(requests, 0, "Preparing a normal window must not start screenshot polling")
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Active fullscreen screenshots") { requests >= 3 }
        window.activeSpaceForTest = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let whenLeaving = requests
        try await state.waitForCleanup()
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(requests, whenLeaving, "Inactive Space must not perform background screenshot requests")
        window.activeSpaceForTest = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Returned fullscreen screenshots") { requests >= whenLeaving + 3 }
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        let beforeExitTransition = requests
        try await WallpaperMirrorTestSupport.waitUntil(description: "Exit transition stays live") {
            requests >= beforeExitTransition + 3
        }
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        let afterExit = requests
        try await state.waitForCleanup()
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(requests, afterExit, "Normal desktop use must not keep polling screenshots")
        observer.removeFromSuperview()
        try await state.waitForCleanup()
    }

    func testFailedEnterClearsPreparedBackgroundAndIgnoresLateDidEnter() async throws {
        _ = NSApplication.shared
        let window = SpaceControlledWindow(contentRect: CGRect(x: 80, y: 80, width: 200, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let state = FullScreenWallpaperState()
        let observer = FullScreenWallpaperObserver.WindowView(state: state, capture: { _ in image })
        window.contentView?.addSubview(observer)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(50))
        NotificationCenter.default.post(name: .fullScreenWindowDidFailToEnter, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(state.hasBackground)
        observer.removeFromSuperview()
    }

    func testFailedExitKeepsTheExistingFullScreenMirror() async throws {
        _ = NSApplication.shared
        let window = SpaceControlledWindow(contentRect: CGRect(x: 80, y: 80, width: 200, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let state = FullScreenWallpaperState()
        let observer = FullScreenWallpaperObserver.WindowView(state: state, capture: { _ in image }, makeMirror: { _ in
            WallpaperMirrorSession(source: { nil }, systemWallpaper: { image },
                                   changes: Empty().eraseToAnyPublisher())
        })
        window.contentView?.addSubview(observer)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Mirror before failed exit") { state.mirror != nil }
        let mirror = state.mirror

        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        NotificationCenter.default.post(name: .fullScreenWindowDidFailToExit, object: window)
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(state.mirror === mirror)
        XCTAssertFalse(mirror?.isClosed == true)
        observer.removeFromSuperview()
        try await state.waitForCleanup()
    }

    func testExitRequestedDuringEnterCleansPreparationAndIgnoresLateDidEnter() async throws {
        _ = NSApplication.shared
        let window = SpaceControlledWindow(contentRect: CGRect(x: 80, y: 80, width: 200, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let image = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let state = FullScreenWallpaperState()
        let observer = FullScreenWallpaperObserver.WindowView(state: state, capture: { _ in image })
        window.contentView?.addSubview(observer)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(50))
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(state.hasBackground)
        observer.removeFromSuperview()
    }
}

@MainActor
private final class SpaceControlledWindow: NSWindow {
    var activeSpaceForTest = true
    override var isOnActiveSpace: Bool { activeSpaceForTest }
}
