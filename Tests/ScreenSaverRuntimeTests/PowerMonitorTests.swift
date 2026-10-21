import AppKit
import XCTest
@testable import ScreenSaverRuntime

@MainActor
final class PowerMonitorTests: XCTestCase {
    func testIOKitClamshellMessagesDecodeLidBitIndependentlyOfSleepPolicy() throws {
        let observation = try ScreenSaverLidObservation()
        var states: [Bool] = []
        observation.onChange = { states.append($0) }
        // IOPM.h's kIOPMMessageClamshellStateChange and kClamshellStateBit.
        // Bit 1 is whether closing causes sleep, not whether the lid is closed.
        for flags in [0, 1, 2, 3] {
            observation.receive(message: 0xe003_4100, argument: UnsafeMutableRawPointer(bitPattern: flags))
        }
        observation.receive(message: 0, argument: UnsafeMutableRawPointer(bitPattern: 1))
        XCTAssertEqual(states, [false, true, false, true])
    }

    func testWorkspaceSignalsPreserveIndependentSleepReasonsAndStopRemovesObservers() throws {
        let center = NotificationCenter()
        var displaySleeping = false
        let monitor = ScreenSaverPowerMonitor(center: center, displaySleeping: { displaySleeping })
        defer { monitor.stop() }
        var states: [ScreenSaverPowerState] = []
        monitor.onChange = { states.append($0) }
        // Opens the real IOKit lid notification source; the isolated center only
        // delivers workspace events without putting the test machine to sleep.
        let initial = try monitor.start()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(states.last, .init(lidClosed: initial.lidClosed, systemSleeping: true))
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertEqual(states.last, .init(lidClosed: initial.lidClosed, displaySleeping: true, systemSleeping: true))
        displaySleeping = true
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(states.last, .init(lidClosed: initial.lidClosed, displaySleeping: true))
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(states.last, .init(lidClosed: initial.lidClosed))
        XCTAssertEqual(states.count, 4)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        XCTAssertEqual(states.count, 4, "Locking/session changes must not stop a visible screen saver")
        monitor.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(states.count, 4)
    }

    func testStartReadsCurrentDisplayStateAndRepeatedStartsDoNotDuplicateObservers() throws {
        let center = NotificationCenter()
        let monitor = ScreenSaverPowerMonitor(center: center, displaySleeping: { true })
        defer { monitor.stop() }
        var count = 0
        monitor.onChange = { _ in count += 1 }
        XCTAssertTrue(try monitor.start().displaySleeping)
        XCTAssertTrue(try monitor.start().displaySleeping)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertEqual(count, 1)
    }
}
