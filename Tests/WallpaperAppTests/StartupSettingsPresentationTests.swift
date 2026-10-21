import AppKit
import ServiceManagement
import XCTest
@testable import WallpaperApp

@MainActor
final class StartupSettingsPresentationTests: XCTestCase {
    func testGeneralShowsBothStartupControlsWithExistingSettings() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        for title in ["登录时启动", "在 Dock 中显示应用图标", "全局静音", "低电量模式时暂停", "设备温度较高时暂停"] {
            _ = try fixture.element(title, role: .checkBox)
        }
        XCTAssertTrue(fixture.contains("启动与运行"))
        XCTAssertFalse(fixture.contains(fixture.model.loginItems.statusMessage))
        let enabled: NSNumber? = try fixture.element("登录时启动", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(enabled?.boolValue, false)
    }

    func testDockSwitchPreservesMenusUntilSettingsCloseAndPersistsPreference() async throws {
        let presentation = TestApplicationPresentation()
        let fixture = try SettingsPresentationFixture(presentation: presentation)
        defer { fixture.close() }
        let managementWindows = ManagementWindowObserver(onChange: fixture.model.setManagementWindowsOpen)
        managementWindows.start()
        defer { managementWindows.stop() }
        try await fixture.show()
        XCTAssertNotNil(try fixture.element("在 Dock 中显示应用图标", role: .checkBox).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertFalse(fixture.model.library.settings.showDockIcon)
        XCTAssertFalse(try fixture.model.store.load().settings.showDockIcon)
        XCTAssertEqual(presentation.activationPolicy, .regular)
        XCTAssertTrue(fixture.window.isVisible)
        fixture.window.close()
        XCTAssertEqual(presentation.activationPolicy, .accessory)
    }

    func testPendingApprovalProvidesSystemSettingsActionWithoutClaimingEnabled() async throws {
        let service = TestLoginItemService()
        service.registrationStatus = .requiresApproval
        let fixture = try SettingsPresentationFixture(loginService: service)
        defer { fixture.close() }
        try await fixture.show()
        XCTAssertNotNil(try fixture.element("登录时启动", role: .checkBox).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertEqual(fixture.model.loginItems.status, .requiresApproval)
        XCTAssertFalse(fixture.contains(fixture.model.loginItems.statusMessage))
        XCTAssertNotNil(try fixture.element("打开系统登录项设置…", role: .button).accessibilityPerformPress?())
        XCTAssertEqual(service.settingsOpens, 1)
    }

    func testNotFoundStatusAllowsTheFirstExplicitRegistration() async throws {
        let service = TestLoginItemService(status: .notFound)
        let fixture = try SettingsPresentationFixture(loginService: service)
        defer { fixture.close() }
        try await fixture.show()
        XCTAssertEqual(service.registrations, 0)
        let toggle = try fixture.element("登录时启动", role: .checkBox)
        XCTAssertEqual(toggle.isAccessibilityEnabled?(), true)
        // NSSwitch can return false after dispatch; verify the real state change below.
        XCTAssertNotNil(toggle.accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertEqual(service.registrations, 1)
        XCTAssertEqual(fixture.model.loginItems.status, .enabled)
        XCTAssertFalse(fixture.contains(fixture.model.loginItems.statusMessage))
        let enabled: NSNumber? = try fixture.element("登录时启动", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(enabled?.boolValue, true)
    }

    func testReturningToGeneralRefreshesExternalLoginChanges() async throws {
        let service = TestLoginItemService()
        let fixture = try SettingsPresentationFixture(loginService: service)
        defer { fixture.close() }
        try await fixture.show()
        try await fixture.selectTab("存储与素材")
        service.status = .enabled
        try await fixture.selectTab("通用")
        XCTAssertEqual(fixture.model.loginItems.status, .enabled)
        let enabled: NSNumber? = try fixture.element("登录时启动", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(enabled?.boolValue, true)
        XCTAssertEqual(service.registrations, 0)
    }

    func testUnregistrationErrorIsVisibleAndSwitchMatchesTheSystem() async throws {
        let service = TestLoginItemService(status: .enabled)
        service.unregistrationError = NSError(domain: "StartupPresentation", code: 9)
        let fixture = try SettingsPresentationFixture(loginService: service)
        defer { fixture.close() }
        try await fixture.show()
        XCTAssertNotNil(try fixture.element("登录时启动", role: .checkBox).accessibilityPerformPress?())
        try await fixture.settle()
        let failure = try XCTUnwrap(fixture.model.loginItems.failure)
        XCTAssertTrue(fixture.contains(failure.summary))
        XCTAssertEqual(fixture.model.loginItems.status, .enabled)
        let enabled: NSNumber? = try fixture.element("登录时启动", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(enabled?.boolValue, true)
    }

    func testDockSaveFailureIsVisibleAndDoesNotChangeTheSwitch() async throws {
        let fixture = try SettingsPresentationFixture()
        defer { fixture.close() }
        try await fixture.show()
        try FileManager.default.removeItem(at: fixture.model.store.url)
        try FileManager.default.createDirectory(at: fixture.model.store.url, withIntermediateDirectories: false)
        XCTAssertNotNil(try fixture.element("在 Dock 中显示应用图标", role: .checkBox).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertTrue(fixture.model.library.settings.showDockIcon)
        XCTAssertTrue(fixture.contains(try XCTUnwrap(fixture.model.presentationFailure).summary))
    }
}
