import XCTest
import WallpaperCore
@testable import WallpaperApp

@MainActor
final class WebInteractionControllerTests: XCTestCase {
    private struct Failure: Error {}
    private final class Recorder { var events: [String] = [] }

    func testMissingPermissionWhileDisabledNeverPersists() {
        let service = TestWebInteractionPermissionService(missing: [.accessibility])
        let recorder = Recorder()
        let controller = makeController(service: service, recorder: recorder)
        let outcome = controller.setEnabled(true, currentEnabled: false,
            persistAndPublish: { _ in recorder.events.append("persist") },
            forcePublish: { _ in recorder.events.append("force") })
        XCTAssertEqual(outcome.result, .needsPermissions([.accessibility]))
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testSuccessfulEnablePersistsAndPublishesBeforeRuntime() {
        let service = TestWebInteractionPermissionService()
        let recorder = Recorder()
        let controller = makeController(service: service, recorder: recorder)
        let outcome = controller.setEnabled(true, currentEnabled: false,
            persistAndPublish: { value in recorder.events.append("persist-\(value)") },
            forcePublish: { value in recorder.events.append("force-\(value)") })
        XCTAssertEqual(outcome.result, .updated)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(recorder.events, ["persist-true", "runtime-true"])
        controller.shutdown()
    }

    func testOrdinaryDisableSaveFailureLeavesRuntimeAndIntentEnabled() {
        let service = TestWebInteractionPermissionService()
        let recorder = Recorder()
        let controller = makeController(service: service, recorder: recorder)
        let outcome = controller.setEnabled(false, currentEnabled: true,
            persistAndPublish: { _ in recorder.events.append("persist"); throw Failure() },
            forcePublish: { _ in recorder.events.append("force") })
        XCTAssertEqual(outcome.result, .failed)
        XCTAssertEqual(recorder.events, ["persist"])
        guard case .persistence(_, runtimeWasForcedOff: false)? = outcome.failure else {
            return XCTFail("Expected ordinary persistence failure")
        }
    }

    func testDisableWhileAlreadyDisabledStillPersistsAndAppliesRuntimeState() {
        let service = TestWebInteractionPermissionService(missing: [.accessibility])
        let recorder = Recorder()
        let controller = makeController(service: service, recorder: recorder)
        let outcome = controller.setEnabled(false, currentEnabled: false,
            persistAndPublish: { value in recorder.events.append("persist-\(value)") },
            forcePublish: { value in recorder.events.append("force-\(value)") })
        XCTAssertEqual(outcome.result, .updated)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(recorder.events, ["persist-false", "runtime-false"])
    }

    func testRevocationForcesRuntimeAndPublishedIntentOffBeforeFailedSave() {
        let service = TestWebInteractionPermissionService(missing: [.inputMonitoring])
        let recorder = Recorder()
        let controller = makeController(service: service, recorder: recorder)
        let failure = controller.refresh(currentEnabled: true,
            persistAndPublish: { value in recorder.events.append("persist-\(value)"); throw Failure() },
            forcePublish: { value in recorder.events.append("force-\(value)") })
        XCTAssertEqual(recorder.events, ["runtime-false", "force-false", "persist-false", "refresh-status"])
        guard case .persistence(_, runtimeWasForcedOff: true)? = failure else {
            return XCTFail("Expected forced-off persistence failure")
        }
    }

    func testPermissionLossDuringEnableRollsBackAfterTheSavedEnable() {
        let service = TestWebInteractionPermissionService()
        service.onRead = { [weak service] count in
            if count == 2 { service?.missingPermissions = [.inputMonitoring] }
        }
        let recorder = Recorder()
        let controller = makeController(service: service, recorder: recorder)
        let outcome = controller.setEnabled(true, currentEnabled: false,
            persistAndPublish: { value in recorder.events.append("persist-\(value)") },
            forcePublish: { value in recorder.events.append("force-\(value)") })
        XCTAssertEqual(outcome.result, .needsPermissions([.inputMonitoring]))
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(recorder.events, ["persist-true", "runtime-true", "runtime-false", "force-false", "persist-false"])
    }

    func testSettingsFailureIsReturnedStructurally() {
        let service = TestWebInteractionPermissionService(missing: [.accessibility])
        service.openError = Failure()
        let recorder = Recorder()
        let controller = makeController(service: service, recorder: recorder)
        guard case .settings? = controller.requestPermission(.accessibility) else {
            return XCTFail("Expected settings failure")
        }
        XCTAssertEqual(service.requestedPermissions, [.accessibility])
        XCTAssertEqual(service.openedPermissions, [.accessibility])
    }

    func testShutdownInvalidatesPermissionPolling() async throws {
        let service = TestWebInteractionPermissionService()
        let recorder = Recorder()
        let controller = makeController(service: service, recorder: recorder)
        controller.onPoll = { _ = service.missingPermissions }
        _ = controller.setEnabled(true, currentEnabled: false,
            persistAndPublish: { _ in }, forcePublish: { _ in })
        controller.shutdown()
        let reads = service.readCount
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(service.readCount, reads)
    }

    private func makeController(service: TestWebInteractionPermissionService,
                                recorder: Recorder) -> WebInteractionController {
        WebInteractionController(permissionService: service,
            setRuntimeEnabled: { recorder.events.append("runtime-\($0)") },
            refreshRuntimeStatus: { recorder.events.append("refresh-status") })
    }
}
