import AppKit
import ScreenSaverRuntime
import XCTest
@testable import WallpaperScreenSaver

@MainActor
final class HostPowerLifecycleTests: XCTestCase {
    func testNewPowerFailureSurvivesThePreviousHostStopCompletion() async throws {
        _ = NSApplication.shared
        let view = try XCTUnwrap(WallpaperScreenSaverView(frame: NSRect(x: 0, y: 0, width: 128, height: 72),
                                                        isPreview: true, power: UnavailableHostPower()))
        // Even an empty native release is asynchronous. Restart before the old
        // host stop callback runs, then fail the new power observation.
        view.stopAnimation()
        view.startAnimation()
        XCTAssertEqual(view.diagnosticState, "failed")
        let message = view.diagnosticMessage
        XCTAssertFalse(message.isEmpty)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(view.diagnosticState, "failed")
        XCTAssertEqual(view.diagnosticMessage, message)
        view.stopAnimation()
    }
}

@MainActor
private final class UnavailableHostPower: ScreenSaverPowerObserving {
    var onChange: ((ScreenSaverPowerState) -> Void)?
    var onError: ((Error) -> Void)?
    func start() throws -> ScreenSaverPowerState {
        throw NSError(domain: "ScreenSaverHostPowerTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Injected power observation failure"])
    }
    func stop() { }
}
