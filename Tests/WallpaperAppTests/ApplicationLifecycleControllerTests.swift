import AppKit
import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class ApplicationLifecycleControllerTests: XCTestCase {
    private struct Failure: Error {}

    func testDuplicateShutdownCallsExecuteOnePlan() async throws {
        let controller = makeController()
        var immediateCount = 0
        var closeTaskCount = 0
        var runtimeCount = 0
        let plan = ApplicationShutdownPlan(immediate: { immediateCount += 1 }, importing: nil,
            drain: {}, makeCloseTasks: {
                closeTaskCount += 1
                return []
            }, requireReleased: {}, shutdownWebRuntime: { runtimeCount += 1 })

        let first = controller.beginShutdown(plan: plan)
        let second = controller.beginShutdown(plan: plan)
        try await first.value
        try await second.value

        XCTAssertEqual(immediateCount, 1)
        XCTAssertEqual(closeTaskCount, 1)
        XCTAssertEqual(runtimeCount, 1)
    }

    func testSynchronousReentrantShutdownUsesTheCachedTask() async throws {
        let controller = makeController()
        var immediateCount = 0
        var closeTaskCount = 0
        var nestedShutdown: Task<Void, Error>?
        var plan: ApplicationShutdownPlan!
        plan = ApplicationShutdownPlan(immediate: {
            immediateCount += 1
            if immediateCount == 1 {
                nestedShutdown = controller.beginShutdown(plan: plan)
            }
        }, importing: nil, drain: {}, makeCloseTasks: {
            closeTaskCount += 1
            return []
        }, requireReleased: {}, shutdownWebRuntime: {})

        let shutdown = controller.beginShutdown(plan: plan)
        try await shutdown.value
        try await XCTUnwrap(nestedShutdown).value

        XCTAssertEqual(immediateCount, 1)
        XCTAssertEqual(closeTaskCount, 1)
    }

    func testShutdownAwaitsImportAndDrainBeforeReleaseValidationAndWebRuntime() async throws {
        var events: [String] = []
        var finishImport: CheckedContinuation<Void, Never>?
        let importing = Task<Bool, Never> { @MainActor in
            await withCheckedContinuation { finishImport = $0 }
            events.append("import")
            return true
        }
        let controller = makeController()
        let plan = ApplicationShutdownPlan(immediate: { events.append("immediate") }, importing: importing,
            drain: { events.append("drain") }, makeCloseTasks: {
                [Task { @MainActor in events.append("close") }]
            }, requireReleased: { events.append("released") },
            shutdownWebRuntime: { events.append("web") })

        let shutdown = controller.beginShutdown(plan: plan)
        await Task.yield()
        XCTAssertFalse(events.contains("released"))
        finishImport?.resume()
        try await shutdown.value

        let importIndex = try XCTUnwrap(events.firstIndex(of: "import"))
        let drainIndex = try XCTUnwrap(events.firstIndex(of: "drain"))
        let releasedIndex = try XCTUnwrap(events.firstIndex(of: "released"))
        let webIndex = try XCTUnwrap(events.firstIndex(of: "web"))
        XCTAssertLessThan(importIndex, drainIndex)
        XCTAssertLessThan(drainIndex, releasedIndex)
        XCTAssertLessThan(releasedIndex, webIndex)
    }

    func testFailedCloseStillAwaitsEveryCloseAndSkipsLaterShutdownStages() async {
        let slowStarted = expectation(description: "slow close started")
        var finishSlow: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let controller = makeController()
        let plan = ApplicationShutdownPlan(immediate: {}, importing: nil, drain: {}, makeCloseTasks: {
            let failed = Task<Void, Error> { throw Failure() }
            let slow = Task<Void, Error> { @MainActor in
                await withCheckedContinuation { finishSlow = $0; slowStarted.fulfill() }
                events.append("slow-finished")
            }
            return [failed, slow]
        }, requireReleased: { events.append("released") },
            shutdownWebRuntime: { events.append("web") })

        let shutdown = controller.beginShutdown(plan: plan)
        await fulfillment(of: [slowStarted], timeout: 1)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(events.isEmpty)
        finishSlow?.resume()
        do {
            try await shutdown.value
            XCTFail("The real close failure must propagate")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        XCTAssertEqual(events, ["slow-finished"])
    }

    func testReleaseValidationRunsAfterAllClosesAndWebRuntimeIsLast() async throws {
        var events: [String] = []
        let controller = makeController()
        let plan = ApplicationShutdownPlan(immediate: {}, importing: nil, drain: {}, makeCloseTasks: {
            [Task { @MainActor in events.append("close-one") },
             Task { @MainActor in events.append("close-two") }]
        }, requireReleased: {
            XCTAssertEqual(Set(events), ["close-one", "close-two"])
            events.append("released")
        }, shutdownWebRuntime: {
            XCTAssertEqual(events.last, "released")
            events.append("web")
        })

        try await controller.beginShutdown(plan: plan).value
        XCTAssertEqual(events.last, "web")
    }

    func testSettingsReachPowerBeforeFullScreenSamplingAndReasonsAreCombined() {
        let power = PowerMonitor()
        var settingsSeenBySample: AppSettings?
        let fullScreen = OtherAppFullScreenMonitor(sample: {
            settingsSeenBySample = power.settings
            return true
        })
        let controller = makeController(power: power, fullScreen: fullScreen)
        var published: [Set<String>] = []
        controller.onPauseReasons = { published.append($0) }
        var settings = AppSettings()
        settings.pauseOnOtherAppFullScreen = true

        controller.update(settings: settings)
        power.onChange?(["系统休眠"])

        XCTAssertEqual(settingsSeenBySample?.pauseOnOtherAppFullScreen, true)
        XCTAssertEqual(published.last, ["系统休眠", "其他应用全屏"])
        _ = controller.beginShutdown(plan: emptyPlan())
    }

    func testQueuedScreenAndPauseCallbacksStopAfterShutdownBegins() async throws {
        let notifications = NotificationCenter()
        let power = PowerMonitor()
        var fullScreenActive = true
        let fullScreen = OtherAppFullScreenMonitor(sample: { fullScreenActive })
        let controller = makeController(power: power, fullScreen: fullScreen,
                                        notifications: notifications)
        var screenPublications = 0
        var pausePublications = 0
        controller.onScreensChanged = { _ in screenPublications += 1 }
        controller.onPauseReasons = { _ in pausePublications += 1 }
        var settings = AppSettings()
        settings.pauseOnOtherAppFullScreen = true
        controller.update(settings: settings)
        let initialPausePublications = pausePublications

        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let shutdown = controller.beginShutdown(plan: emptyPlan())
        fullScreenActive = false
        fullScreen.refresh()
        power.onChange?(["系统休眠"])
        await Task.yield()
        try await shutdown.value

        XCTAssertEqual(screenPublications, 0)
        XCTAssertEqual(pausePublications, initialPausePublications)
    }

    private func makeController(power: PowerMonitor? = nil,
                                fullScreen: OtherAppFullScreenMonitor? = nil,
                                notifications: NotificationCenter = NotificationCenter())
        -> ApplicationLifecycleController {
        ApplicationLifecycleController(power: power,
            fullScreenMonitor: fullScreen ?? OtherAppFullScreenMonitor(sample: { false }),
            notificationCenter: notifications, screens: { [] })
    }

    private func emptyPlan() -> ApplicationShutdownPlan {
        ApplicationShutdownPlan(immediate: {}, importing: nil, drain: {}, makeCloseTasks: { [] },
                                requireReleased: {}, shutdownWebRuntime: {})
    }
}
