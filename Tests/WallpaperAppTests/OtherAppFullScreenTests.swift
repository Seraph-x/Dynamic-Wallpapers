import AppKit
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class OtherAppFullScreenTests: XCTestCase {
    func testDetectsExternalFullScreenRegardlessOfWindowOrderOrFrontmostApplication() {
        let first = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let second = CGRect(x: 1920, y: -360, width: 2560, height: 1440)
        let displays = [first, second]
        let normal = OtherAppFullScreenMonitor.Window(owner: 20, layer: 0,
                                                       bounds: CGRect(x: 50, y: 50, width: 900, height: 600))
        let sameAppFullScreen = OtherAppFullScreenMonitor.Window(owner: 20, layer: 0, bounds: second)
        XCTAssertTrue(OtherAppFullScreenMonitor.containsFullScreenWindow(
            [normal, sameAppFullScreen], displays: displays, ownPID: 10),
            "A full-screen window must be detected even when a normal window precedes it")
        let backgroundAppFullScreen = OtherAppFullScreenMonitor.Window(owner: 30, layer: 0, bounds: first)
        XCTAssertTrue(OtherAppFullScreenMonitor.containsFullScreenWindow(
            [normal, backgroundAppFullScreen], displays: displays, ownPID: 10),
            "A full-screen window must not depend on its owner being the frontmost application")
        XCTAssertTrue(OtherAppFullScreenMonitor.containsFullScreenWindow(
            [backgroundAppFullScreen, normal], displays: displays, ownPID: 10),
            "Window-list ordering must not affect detection")
    }

    func testRequiresOneExternalOwnerAtNormalLayerToCoverAnEntireDisplay() {
        let first = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let second = CGRect(x: 1920, y: -360, width: 2560, height: 1440)
        let displays = [first, second]
        func matches(_ owner: pid_t, _ layer: Int, _ bounds: CGRect) -> Bool {
            OtherAppFullScreenMonitor.containsFullScreenWindow(
                [.init(owner: owner, layer: layer, bounds: bounds)], displays: displays,
                ownPID: 10)
        }
        XCTAssertTrue(matches(20, 0, second))
        XCTAssertFalse(matches(10, 0, first), "Our own full-screen settings must not pause wallpaper")
        XCTAssertFalse(matches(20, -1, first), "Desktop windows are not full-screen apps")
        XCTAssertFalse(matches(20, 0, CGRect(x: 1920, y: -360, width: 2560, height: 1400)))
        XCTAssertFalse(matches(20, 0, CGRect(x: 0, y: 0, width: 4480, height: 1440)))
        let splitBetweenApps = [
            OtherAppFullScreenMonitor.Window(owner: 20, layer: 0,
                bounds: CGRect(x: 0, y: 0, width: 960, height: 1080)),
            OtherAppFullScreenMonitor.Window(owner: 30, layer: 0,
                bounds: CGRect(x: 960, y: 0, width: 960, height: 1080)),
        ]
        XCTAssertFalse(OtherAppFullScreenMonitor.containsFullScreenWindow(
            splitBetweenApps, displays: displays, ownPID: 10),
            "Different applications must not be combined into a synthetic full-screen app")
    }

    func testDetectsFullScreenFromOneApplicationsGenericWindowPieces() {
        let first = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let second = CGRect(x: 1920, y: -360, width: 2560, height: 1440)
        let displays = [first, second]
        let normal = OtherAppFullScreenMonitor.Window(owner: 20, layer: 0,
                                                       bounds: CGRect(x: 50, y: 50, width: 900, height: 600))
        let fullScreen = OtherAppFullScreenMonitor.Window(owner: 20, layer: 0, bounds: second)
        XCTAssertTrue(OtherAppFullScreenMonitor.containsFullScreenWindow(
            [normal, fullScreen], displays: displays, ownPID: 10),
            "A normal window on another display must not hide a full-screen window")
        let offscreenDecoration = OtherAppFullScreenMonitor.Window(owner: 20, layer: 0,
            bounds: CGRect(x: 0, y: -44, width: 1920, height: 44))
        XCTAssertTrue(OtherAppFullScreenMonitor.containsFullScreenWindow(
            [offscreenDecoration, .init(owner: 20, layer: 0, bounds: first)],
            displays: displays, ownPID: 10),
            "An offscreen full-screen decoration must not hide the actual full-screen window")

        let genericPieces: [OtherAppFullScreenMonitor.Window] = [
            .init(owner: 20, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 41)),
            .init(owner: 20, layer: 0, bounds: CGRect(x: 0, y: 41, width: 1920, height: 47)),
            .init(owner: 20, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 124)),
            .init(owner: 20, layer: 0, bounds: CGRect(x: 0, y: 88, width: 1920, height: 992)),
        ]
        XCTAssertTrue(OtherAppFullScreenMonitor.containsFullScreenWindow(
            genericPieces, displays: displays, ownPID: 10),
            "A full-screen app may cover its display with several normal-layer windows")
        XCTAssertFalse(OtherAppFullScreenMonitor.containsFullScreenWindow(
            Array(genericPieces.dropLast()), displays: displays, ownPID: 10),
            "Window pieces that leave part of the display uncovered are not full screen")
        let gapped = [
            OtherAppFullScreenMonitor.Window(owner: 20, layer: 0,
                bounds: CGRect(x: 0, y: 0, width: 1920, height: 450)),
            OtherAppFullScreenMonitor.Window(owner: 20, layer: 0,
                bounds: CGRect(x: 0, y: 452, width: 1920, height: 628)),
        ]
        XCTAssertFalse(OtherAppFullScreenMonitor.containsFullScreenWindow(
            gapped, displays: displays, ownPID: 10),
            "The bounding box alone must not hide an uncovered gap")
    }

    func testSettingAndFullScreenChangesPreserveManualPause() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(url: directory.appendingPathComponent("library.json"))
        try store.save(.empty)
        var otherAppIsFullScreen = false
        let monitor = OtherAppFullScreenMonitor(sample: { otherAppIsFullScreen })
        let model = AppModel(store: store, fullScreenMonitor: monitor)
        defer { model.shutdown() }
        XCTAssertFalse(model.isPaused)
        otherAppIsFullScreen = true
        XCTAssertTrue(model.mutate { $0.settings.pauseOnOtherAppFullScreen = true })
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.pauseReasons.contains("其他应用全屏"))
        XCTAssertTrue(try store.load().settings.pauseOnOtherAppFullScreen)

        model.togglePause()
        otherAppIsFullScreen = false
        monitor.refresh()
        XCTAssertTrue(model.isPaused, "Leaving full screen must not cancel manual pause")
        XCTAssertTrue(model.pauseReasons.isEmpty)
        model.togglePause()
        XCTAssertFalse(model.isPaused)

        otherAppIsFullScreen = true
        monitor.refresh()
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.mutate { $0.settings.pauseOnOtherAppFullScreen = false })
        XCTAssertFalse(model.isPaused)
        XCTAssertFalse(try store.load().settings.pauseOnOtherAppFullScreen)
        try await model.shutdownAndWait()
    }

    func testSpaceSwitchResumesOnNormalDesktopAndPausesOnReturn() async throws {
        _ = NSApplication.shared
        var activeSpaceIsFullScreen = true
        let monitor = OtherAppFullScreenMonitor(sample: { activeSpaceIsFullScreen })
        defer { monitor.shutdown() }
        monitor.setEnabled(true)
        XCTAssertTrue(monitor.isActive)

        activeSpaceIsFullScreen = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Normal desktop resumes playback") {
            !monitor.isActive
        }

        activeSpaceIsFullScreen = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try await WallpaperMirrorTestSupport.waitUntil(description: "Return to full-screen Space pauses playback") {
            monitor.isActive
        }
    }

    func testSettingsToggleIsVisibleAndSaved() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        let toggle = try fixture.element("其他应用全屏时暂停", role: .checkBox)
        XCTAssertEqual((toggle.accessibilityValue?() as NSNumber?)?.boolValue, false)
        XCTAssertNotNil(toggle.accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertTrue(fixture.model.library.settings.pauseOnOtherAppFullScreen)
        XCTAssertTrue(try fixture.model.store.load().settings.pauseOnOtherAppFullScreen)
        try await fixture.model.shutdownAndWait()
    }

    func testSamplingFailureIsReportedWithoutInventingAResume() {
        var failure: Error?
        let monitor = OtherAppFullScreenMonitor(sample: {
            if let failure { throw failure }
            return true
        })
        defer { monitor.shutdown() }
        var reported: [String] = []
        monitor.onError = { reported.append($0.localizedDescription) }
        monitor.setEnabled(true)
        XCTAssertTrue(monitor.isActive)
        failure = WallpaperError("窗口列表读取失败")
        monitor.refresh()
        monitor.refresh()
        XCTAssertTrue(monitor.isActive)
        XCTAssertEqual(reported.count, 1)
        failure = nil
        monitor.refresh()
        monitor.setEnabled(false)
        XCTAssertFalse(monitor.isActive)
    }
}
