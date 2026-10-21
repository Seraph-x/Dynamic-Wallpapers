import ServiceManagement
import XCTest
@testable import WallpaperApp

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testConstructionReadsSystemStateWithoutChangingRegistration() {
        let service = TestLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isRequested)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertEqual(service.unregistrations, 0)
    }

    func testEnableAndDisableUseQueriedSystemState() {
        let service = TestLoginItemService()
        let controller = LoginItemController(service: service)
        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertEqual(service.registrations, 1)
        XCTAssertTrue(controller.setEnabled(false))
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isRequested)
        XCTAssertEqual(service.unregistrations, 1)
    }

    func testPendingApprovalIsDistinctFromEnabledAndCanBeRevoked() {
        let service = TestLoginItemService()
        service.registrationStatus = .requiresApproval
        let controller = LoginItemController(service: service)
        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(controller.isRequested)
        XCTAssertTrue(controller.statusMessage.contains("允许"))
        controller.openSystemSettings()
        XCTAssertEqual(service.settingsOpens, 1)
        XCTAssertTrue(controller.setEnabled(false))
        XCTAssertEqual(controller.status, .notRegistered)
    }

    func testFailedRegistrationReportsOriginalErrorAndActualPendingState() throws {
        let service = TestLoginItemService()
        service.registrationStatus = .requiresApproval
        service.registrationError = NSError(domain: "LoginTest", code: 42)
        let controller = LoginItemController(service: service)
        XCTAssertFalse(controller.setEnabled(true))
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertTrue(try XCTUnwrap(controller.failure?.diagnostics).contains("LoginTest"))
        XCTAssertFalse(controller.isChanging)
    }

    func testFailedUnregistrationKeepsSystemStateAndCanBeRetried() throws {
        let service = TestLoginItemService(status: .enabled)
        service.unregistrationError = NSError(domain: "UnregisterTest", code: 7)
        let controller = LoginItemController(service: service)
        XCTAssertFalse(controller.setEnabled(false))
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNotNil(controller.failure)
        service.unregistrationError = nil
        XCTAssertTrue(controller.setEnabled(false))
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertNil(controller.failure)
    }

    func testAPIReturnWithoutExpectedStateIsNotReportedAsSuccess() {
        let service = TestLoginItemService()
        service.registrationStatus = .notRegistered
        let controller = LoginItemController(service: service)
        XCTAssertFalse(controller.setEnabled(true))
        XCTAssertNotNil(controller.failure)
        XCTAssertFalse(controller.isRequested)
    }

    func testRefreshReflectsExternalChangesWithoutRegistration() {
        let service = TestLoginItemService()
        let controller = LoginItemController(service: service)
        service.status = .enabled
        controller.refresh()
        XCTAssertEqual(controller.status, .enabled)
        service.status = .requiresApproval
        controller.refresh()
        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertEqual(service.registrations, 0)
    }

    func testNotFoundInitialStatusCanRegisterOnlyOnExplicitRequest() {
        let service = TestLoginItemService(status: .notFound)
        let controller = LoginItemController(service: service)
        XCTAssertEqual(controller.status, .notFound)
        XCTAssertFalse(controller.isRequested)
        XCTAssertEqual(service.registrations, 0)
        XCTAssertTrue(controller.canChange)
        XCTAssertTrue(controller.setEnabled(true))
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertNil(controller.failure)
    }

    func testNotFoundRegistrationFailurePreservesActualStateAndDiagnostics() throws {
        let service = TestLoginItemService(status: .notFound)
        service.registrationStatus = .notFound
        service.registrationError = NSError(domain: "SMAppServiceTest", code: 2)
        let controller = LoginItemController(service: service)
        XCTAssertFalse(controller.setEnabled(true))
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(controller.status, .notFound)
        XCTAssertFalse(controller.isRequested)
        XCTAssertTrue(try XCTUnwrap(controller.failure?.diagnostics).contains("SMAppServiceTest"))
        XCTAssertTrue(controller.canChange)
    }

    func testShutdownPreventsChangesWithoutUnregisteringExistingChoice() {
        let service = TestLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)
        controller.shutdown()
        XCTAssertFalse(controller.canChange)
        XCTAssertFalse(controller.setEnabled(false))
        XCTAssertNotNil(controller.failure)
        XCTAssertEqual(service.unregistrations, 0)
        XCTAssertEqual(controller.status, .enabled)
    }
}

@MainActor
final class TestLoginItemService: LoginItemServicing {
    var status: SMAppService.Status
    var registrationStatus: SMAppService.Status = .enabled
    var registrationError: Error?
    var unregistrationError: Error?
    private(set) var registrations = 0
    private(set) var unregistrations = 0
    private(set) var settingsOpens = 0
    init(status: SMAppService.Status = .notRegistered) { self.status = status }
    func register() throws {
        registrations += 1
        status = registrationStatus
        if let registrationError { throw registrationError }
    }
    func unregister() throws {
        unregistrations += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }
    func openSystemSettings() { settingsOpens += 1 }
}
