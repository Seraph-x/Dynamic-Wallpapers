import AppKit
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WebInteractionPermissionTests: XCTestCase {
    func testMissingAccessibilityCannotEnableOrPersistInteraction() throws {
        try assertCannotEnable(missing: [.accessibility])
    }

    func testMissingInputMonitoringCannotEnableOrPersistInteraction() throws {
        try assertCannotEnable(missing: [.inputMonitoring])
    }

    func testMissingBothPermissionsCannotEnableOrPersistInteraction() throws {
        try assertCannotEnable(missing: [.accessibility, .inputMonitoring])
    }

    func testBothPermissionsAllowAnExplicitEnable() throws {
        let model = try makeModel(service: TestWebInteractionPermissionService())
        model.setWebInteractionEnabled(true)
        XCTAssertTrue(model.library.settings.webInteractionEnabled)
        XCTAssertTrue(try model.store.load().settings.webInteractionEnabled)
    }

    func testGrantingPermissionRequiresAnotherExplicitEnable() throws {
        let service = TestWebInteractionPermissionService(missing: [.inputMonitoring])
        let model = try makeModel(service: service)
        model.setWebInteractionEnabled(true)
        service.missingPermissions = []
        model.refreshWebInteractionStatus()
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
        XCTAssertFalse(try model.store.load().settings.webInteractionEnabled)

        model.setWebInteractionEnabled(true)
        XCTAssertTrue(model.library.settings.webInteractionEnabled)
        XCTAssertTrue(try model.store.load().settings.webInteractionEnabled)
    }

    func testRevocationClearsTheSavedSwitchAndGrantDoesNotRestoreIt() throws {
        let service = TestWebInteractionPermissionService()
        let model = try makeModel(service: service)
        model.setWebInteractionEnabled(true)
        service.missingPermissions = [.accessibility]
        model.refreshWebInteractionStatus()
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
        XCTAssertFalse(try model.store.load().settings.webInteractionEnabled)

        service.missingPermissions = []
        model.refreshWebInteractionStatus()
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
    }

    func testStartupClearsAnEnabledSettingWhenPermissionIsMissing() throws {
        let service = TestWebInteractionPermissionService(missing: [.inputMonitoring])
        let model = try makeModel(service: service, savedEnabled: true)
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
        XCTAssertFalse(try model.store.load().settings.webInteractionEnabled)
    }

    func testOrdinaryDisablePersistsAndStopsInteraction() throws {
        let model = try makeModel(service: TestWebInteractionPermissionService(), savedEnabled: true)
        XCTAssertTrue(model.library.settings.webInteractionEnabled)
        XCTAssertEqual(model.setWebInteractionEnabled(false), .updated)
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
        XCTAssertFalse(try model.store.load().settings.webInteractionEnabled)
        XCTAssertEqual(model.webInteractionStatus.message, "网页交互已关闭")
    }

    func testEnableSaveFailureKeepsThePreviousStateAndReportsIt() throws {
        let model = try makeModel(service: TestWebInteractionPermissionService())
        let before = model.library
        try blockSaving(model)
        XCTAssertEqual(model.setWebInteractionEnabled(true), .failed)
        XCTAssertEqual(model.library, before)
        XCTAssertNotNil(model.webInteractionFailure?.diagnostics)
        XCTAssertEqual(model.webInteractionStatus.message, "网页交互已关闭")
    }

    func testOrdinaryDisableSaveFailurePreservesTheEnabledSetting() throws {
        let model = try makeModel(service: TestWebInteractionPermissionService(), savedEnabled: true)
        try blockSaving(model)
        XCTAssertEqual(model.setWebInteractionEnabled(false), .failed)
        XCTAssertTrue(model.library.settings.webInteractionEnabled)
        XCTAssertNotNil(model.webInteractionFailure?.diagnostics)
    }

    func testRevocationSaveFailureStillStopsAndUnchecksInteraction() throws {
        let service = TestWebInteractionPermissionService()
        let model = try makeModel(service: service, savedEnabled: true)
        try blockSaving(model)
        service.missingPermissions = [.inputMonitoring]
        model.refreshWebInteractionStatus()
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
        XCTAssertEqual(model.webInteractionStatus.message, "网页交互已关闭")
        XCTAssertNotNil(model.webInteractionFailure?.diagnostics)
        service.missingPermissions = []
        model.refreshWebInteractionStatus()
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
        XCTAssertNotNil(model.webInteractionFailure, "A later refresh must not hide the failed save")
    }

    func testClearMediaLibraryPreservesTheInteractionSetting() throws {
        let model = try makeModel(service: TestWebInteractionPermissionService(), savedEnabled: true)
        let item = MediaItem(url: model.store.url.deletingLastPathComponent().appendingPathComponent("sample.png"),
                             kind: .image, width: 1, height: 1)
        XCTAssertTrue(model.mutate { $0.media = [item] })
        XCTAssertTrue(model.clearMediaLibrary())
        XCTAssertTrue(model.library.media.isEmpty)
        XCTAssertTrue(model.library.settings.webInteractionEnabled)
        XCTAssertTrue(try model.store.load().settings.webInteractionEnabled)
        XCTAssertNil(model.failure)
    }

    func testApplicationActivationRechecksPermissions() throws {
        let service = TestWebInteractionPermissionService()
        let model = try makeModel(service: service, savedEnabled: true)
        let delegate = AppDelegate()
        delegate.model = model
        service.missingPermissions = [.accessibility]
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
        XCTAssertFalse(try model.store.load().settings.webInteractionEnabled)
    }

    func testEnabledInteractionDetectsRevocationWithoutOpeningTheMenu() async throws {
        let service = TestWebInteractionPermissionService()
        let model = try makeModel(service: service, savedEnabled: true)
        service.missingPermissions = [.inputMonitoring]
        try await WallpaperMirrorTestSupport.waitUntil(timeout: 4, description: "Permission revocation poll") {
            !model.library.settings.webInteractionEnabled
        }
        XCTAssertFalse(try model.store.load().settings.webInteractionEnabled)
        XCTAssertEqual(model.webInteractionStatus.message, "网页交互已关闭")
    }

    func testShutdownInvalidatesMonitoringAndDoesNotRewriteSavedIntent() async throws {
        let service = TestWebInteractionPermissionService()
        let model = try makeModel(service: service, savedEnabled: true)
        try await model.shutdownAndWait()
        service.missingPermissions = [.accessibility, .inputMonitoring]
        model.refreshWebInteractionStatus()
        let reads = service.readCount
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(service.readCount, reads, "Permission polling must stop during shutdown")
        XCTAssertTrue(model.library.settings.webInteractionEnabled)
        XCTAssertTrue(try model.store.load().settings.webInteractionEnabled)
        XCTAssertEqual(model.setWebInteractionEnabled(false), .failed)
    }

    func testSettingsOpenFailureIsVisibleAndNeverEnablesInteraction() throws {
        let service = TestWebInteractionPermissionService(missing: [.inputMonitoring])
        service.openError = WallpaperError("Settings could not open", diagnostic: "test settings failure")
        let model = try makeModel(service: service)
        XCTAssertFalse(model.requestWebInteractionPermission(.inputMonitoring))
        XCTAssertEqual(service.requestedPermissions, [.inputMonitoring])
        XCTAssertEqual(service.openedPermissions, [.inputMonitoring])
        XCTAssertEqual(model.webInteractionFailure?.summary, "无法打开系统隐私设置。")
        XCTAssertTrue(model.webInteractionFailure?.diagnostics?.contains("test settings failure") == true)
        XCTAssertFalse(model.library.settings.webInteractionEnabled)
        XCTAssertFalse(try model.store.load().settings.webInteractionEnabled)
    }

    func testShutdownDoesNotRequestPermissionOrOpenSettings() async throws {
        let service = TestWebInteractionPermissionService(missing: [.accessibility])
        let model = try makeModel(service: service)
        try await model.shutdownAndWait()
        XCTAssertFalse(model.requestWebInteractionPermission(.accessibility))
        XCTAssertTrue(service.requestedPermissions.isEmpty)
        XCTAssertTrue(service.openedPermissions.isEmpty)
        XCTAssertFalse(try model.store.load().settings.webInteractionEnabled)
    }

    func testPermissionLossDuringEnableCannotLeaveTheSettingOn() throws {
        let service = TestWebInteractionPermissionService()
        let model = try makeModel(service: service)
        let before = model.library
        service.onRead = { [weak service] count in
            if count == 2 { service?.missingPermissions = [.inputMonitoring] }
        }
        XCTAssertEqual(model.setWebInteractionEnabled(true), .needsPermissions([.inputMonitoring]))
        XCTAssertEqual(model.library, before)
        XCTAssertEqual(try model.store.load(), before)
        XCTAssertEqual(model.webInteractionStatus.message, "网页交互已关闭")
    }

    func testUnreadableLibraryRejectsTheChangeWithoutOverwritingIt() async throws {
        let service = TestWebInteractionPermissionService()
        let initial = try makeModel(service: service)
        let invalid = Data("not a library".utf8)
        try invalid.write(to: initial.store.url)
        let model = AppModel(store: initial.store, webInteractionPermissions: service)
        defer { model.shutdown() }
        let reads = service.readCount
        XCTAssertTrue(model.loadFailed)
        XCTAssertEqual(model.setWebInteractionEnabled(true), .failed)
        XCTAssertNotNil(model.webInteractionFailure)
        XCTAssertEqual(service.readCount, reads)
        XCTAssertEqual(try Data(contentsOf: model.store.url), invalid)
        try await model.shutdownAndWait()
    }

    private func blockSaving(_ model: AppModel) throws {
        try FileManager.default.removeItem(at: model.store.url)
        try FileManager.default.createDirectory(at: model.store.url, withIntermediateDirectories: false)
    }

    private func assertCannotEnable(missing: [WebInteractionPermission]) throws {
        let model = try makeModel(service: TestWebInteractionPermissionService(missing: missing))
        let before = model.library
        XCTAssertEqual(model.setWebInteractionEnabled(true), .needsPermissions(missing))
        XCTAssertEqual(model.library, before, "An unauthorized request must not change the library")
        XCTAssertEqual(try model.store.load(), before, "An unauthorized request must not be persisted")
    }

    private func makeModel(service: TestWebInteractionPermissionService,
                           savedEnabled: Bool = false) throws -> AppModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-permission-test-\(UUID())")
        let store = LibraryStore(url: root.appendingPathComponent("library.json"))
        var library = Library.empty
        library.settings.webInteractionEnabled = savedEnabled
        try store.save(library)
        let model = AppModel(store: store, webInteractionPermissions: service)
        addTeardownBlock {
            try await model.shutdownAndWait()
            try FileManager.default.removeItem(at: root)
        }
        return model
    }
}

@MainActor
final class TestWebInteractionPermissionService: WebInteractionPermissionServicing {
    private var missing: [WebInteractionPermission]
    private(set) var readCount = 0
    var missingPermissions: [WebInteractionPermission] {
        get { readCount += 1; onRead?(readCount); return missing }
        set { missing = newValue }
    }
    var onRead: ((Int) -> Void)?
    var onRequest: ((WebInteractionPermission) -> Void)?
    var openError: Error?
    private(set) var requestedPermissions: [WebInteractionPermission] = []
    private(set) var openedPermissions: [WebInteractionPermission] = []
    init(missing: [WebInteractionPermission] = []) { self.missing = missing }
    func request(_ permission: WebInteractionPermission) {
        requestedPermissions.append(permission)
        onRequest?(permission)
    }
    func openSettings(for permission: WebInteractionPermission) throws {
        openedPermissions.append(permission)
        if let openError { throw openError }
    }
}
