import AppKit
import SwiftUI
import WallpaperCore
import XCTest
@testable import WallpaperApp

@MainActor
final class WebInteractionPermissionPresentationTests: XCTestCase {
    private let languages: [AppLanguage] = [.chinese, .english, .japanese, .french, .spanish]

    func testAlertsListOnlyMissingPermissionsWithLocalizedActions() {
        for language in languages {
            let l10n = AppLocalizer(language: language)
            for missing: [WebInteractionPermission] in [[.accessibility], [.inputMonitoring], WebInteractionPermission.allCases] {
                let alert = WebInteractionPermissionAlert.makeAlert(missing: missing, localizer: l10n)
                XCTAssertEqual(alert.messageText, l10n("网页交互需要授权"))
                XCTAssertEqual(alert.buttons.map(\.title), missing.map { l10n.text($0.settingsTitle) } + [l10n("取消")])
                XCTAssertEqual(alert.buttons.last?.keyEquivalent, "\u{1b}")
                XCTAssertTrue(alert.informativeText.contains(l10n("授权后，请返回菜单再次开启“网页交互”。")))
                for permission in WebInteractionPermission.allCases {
                    XCTAssertEqual(alert.informativeText.contains("• \(l10n.text(permission.title))"), missing.contains(permission))
                }
            }
        }
    }

    func testAlertHeadersAreCenteredWithoutChangingNativeBodyOrButtons() throws {
        for language in languages {
            for missing: [WebInteractionPermission] in [[.accessibility], [.inputMonitoring], WebInteractionPermission.allCases] {
                let alert = WebInteractionPermissionAlert.makeAlert(missing: missing, localizer: AppLocalizer(language: language))
                let native = NSAlert()
                native.alertStyle = alert.alertStyle
                native.messageText = alert.messageText
                native.informativeText = alert.informativeText
                for button in alert.buttons { native.addButton(withTitle: button.title) }
                native.layout()

                try Self.assertCenteredHeader(alert)
                let content = try XCTUnwrap(alert.window.contentView)
                let nativeContent = try XCTUnwrap(native.window.contentView)
                let body = try XCTUnwrap(content.subviews.compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == alert.informativeText })
                let nativeBody = try XCTUnwrap(nativeContent.subviews.compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == native.informativeText })
                XCTAssertEqual(content.bounds.size, nativeContent.bounds.size)
                XCTAssertEqual(body.frame, nativeBody.frame)
                XCTAssertEqual(body.alignment, nativeBody.alignment)
                for (button, nativeButton) in zip(alert.buttons, native.buttons) {
                    XCTAssertEqual(content.convert(button.bounds, from: button),
                                   nativeContent.convert(nativeButton.bounds, from: nativeButton))
                }
            }
        }
    }

    func testAlertResponsesSelectTheirOwnPermissionAndCancelDoesNothing() {
        for missing: [WebInteractionPermission] in [[.accessibility], [.inputMonitoring], WebInteractionPermission.allCases] {
            for (index, permission) in missing.enumerated() {
                let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
                XCTAssertEqual(WebInteractionPermissionAlert.selectedPermission(response: response, missing: missing), permission)
            }
            let cancel = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + missing.count)
            XCTAssertNil(WebInteractionPermissionAlert.selectedPermission(response: cancel, missing: missing))
            XCTAssertNil(WebInteractionPermissionAlert.selectedPermission(response: .abort, missing: missing))
        }
    }

    func testSettingsURLsTargetTheSpecificPrivacyPanes() {
        XCTAssertEqual(WebInteractionPermission.accessibility.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(WebInteractionPermission.inputMonitoring.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func testMenuCancelLeavesTheRealCheckboxUncheckedAndCanPromptAgain() async throws {
        let service = TestWebInteractionPermissionService(missing: [.accessibility, .inputMonitoring])
        var prompts: [[WebInteractionPermission]] = []
        let fixture = try SettingsPresentationFixture(content: { model in
            AnyView(VStack { MenuContent(model: model, product: ProductMetadataTestSupport.product,
                permissionPrompt: { missing, _ in
                prompts.append(missing)
                return nil
            }) })
        }, webInteractionPermissions: service)
        defer { fixture.close() }
        try await fixture.show(readyText: "播放列表")
        for _ in 0..<2 {
            XCTAssertNotNil(try fixture.element("网页交互", role: .checkBox).accessibilityPerformPress?())
            try await fixture.settle()
            try assertUnchecked(fixture)
        }
        XCTAssertEqual(prompts, [[.accessibility, .inputMonitoring], [.accessibility, .inputMonitoring]])
        XCTAssertTrue(service.requestedPermissions.isEmpty)
        XCTAssertTrue(service.openedPermissions.isEmpty)
        try await fixture.model.shutdownAndWait()
    }

    func testEachAuthorizationActionStillRequiresANewMenuClickToEnable() async throws {
        let service = TestWebInteractionPermissionService(missing: [.accessibility, .inputMonitoring])
        service.onRequest = { [weak service] permission in service?.missingPermissions.removeAll { $0 == permission } }
        var prompts: [[WebInteractionPermission]] = []
        let fixture = try SettingsPresentationFixture(content: { model in
            AnyView(VStack { MenuContent(model: model, product: ProductMetadataTestSupport.product,
                permissionPrompt: { missing, _ in
                prompts.append(missing)
                return missing.first
            }) })
        }, webInteractionPermissions: service)
        defer { fixture.close() }
        try await fixture.show(readyText: "播放列表")
        for _ in 0..<2 {
            XCTAssertNotNil(try fixture.element("网页交互", role: .checkBox).accessibilityPerformPress?())
            try await fixture.settle()
            fixture.model.refreshWebInteractionStatus()
            try assertUnchecked(fixture)
        }
        XCTAssertEqual(prompts, [[.accessibility, .inputMonitoring], [.inputMonitoring]])
        XCTAssertEqual(service.requestedPermissions, [.accessibility, .inputMonitoring])
        XCTAssertEqual(service.openedPermissions, [.accessibility, .inputMonitoring])

        XCTAssertNotNil(try fixture.element("网页交互", role: .checkBox).accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertTrue(fixture.model.library.settings.webInteractionEnabled)
        XCTAssertTrue(try fixture.model.store.load().settings.webInteractionEnabled)
        let selected: NSNumber? = try fixture.element("网页交互", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(selected?.boolValue, true)
        XCTAssertEqual(prompts.count, 2)

        service.missingPermissions = [.accessibility]
        fixture.model.refreshWebInteractionStatus()
        try await fixture.settle()
        try assertUnchecked(fixture)
        try await fixture.model.shutdownAndWait()
    }

    func testMenuShowsActionableSettingsErrorsWithoutRestoringDescriptionText() async throws {
        let service = TestWebInteractionPermissionService(missing: [.accessibility])
        service.openError = WallpaperError("Settings open failed")
        let fixture = try SettingsPresentationFixture(content: { model in
            AnyView(VStack { MenuContent(model: model, product: ProductMetadataTestSupport.product) })
        }, webInteractionPermissions: service)
        defer { fixture.close() }
        XCTAssertFalse(fixture.model.requestWebInteractionPermission(.accessibility))
        try await fixture.show(readyText: "播放列表")
        XCTAssertTrue(fixture.contains("网页交互设置未完成…"))
        XCTAssertFalse(fixture.contains("网页交互已关闭"))
        try assertUnchecked(fixture)
        try await fixture.model.shutdownAndWait()
    }

    func testDefaultPermissionPromptKeepsTheCheckboxOffWhileVisible() async throws {
        let service = TestWebInteractionPermissionService(missing: [.accessibility, .inputMonitoring])
        let fixture = try SettingsPresentationFixture(content: { model in
            AnyView(VStack { MenuContent(model: model, product: ProductMetadataTestSupport.product) })
        }, webInteractionPermissions: service)
        defer { fixture.close() }
        try await fixture.show(readyText: "播放列表")
        let observation = PermissionModalObservation(
            checkbox: try fixture.element("网页交互", role: .checkBox))
        let cancel = Timer(timeInterval: 0.1, repeats: true) { timer in
            let didPresent = MainActor.assumeIsolated {
                guard NSApplication.shared.modalWindow != nil else { return false }
                observation.sawModal = true
                XCTAssertFalse(fixture.model.library.settings.webInteractionEnabled)
                let selected: NSNumber? = observation.checkbox.accessibilityValue?()
                XCTAssertEqual(selected?.boolValue, false,
                               "The checkbox must remain off even while the dialog is visible")
                NSApplication.shared.stopModal(withCode: .alertThirdButtonReturn)
                return true
            }
            if didPresent { timer.invalidate() }
        }
        RunLoop.main.add(cancel, forMode: .modalPanel)
        defer { cancel.invalidate() }
        XCTAssertNotNil(observation.checkbox.accessibilityPerformPress?())
        try await fixture.settle()
        XCTAssertTrue(observation.sawModal, "The real default menu action must present its native permission dialog")
        try assertUnchecked(fixture)
        XCTAssertTrue(service.requestedPermissions.isEmpty)
        XCTAssertTrue(service.openedPermissions.isEmpty)
        try await fixture.model.shutdownAndWait()
    }

    func testNativePermissionDialogKeepsHeaderCenteredAndCanBeCancelled() {
        NSApplication.shared.finishLaunching()
        for language in languages {
            for missing: [WebInteractionPermission] in [[.accessibility], [.inputMonitoring], WebInteractionPermission.allCases] {
                let alert = WebInteractionPermissionAlert.makeAlert(missing: missing, localizer: AppLocalizer(language: language))
                var sawModal = false
                let cancel = Timer(timeInterval: 0.1, repeats: true) { timer in
                    let didPresent = MainActor.assumeIsolated {
                        guard NSApplication.shared.modalWindow === alert.window else { return false }
                        sawModal = true
                        do { try Self.assertCenteredHeader(alert) }
                        catch { XCTFail("Cannot inspect the modal permission dialog's header: \(error)") }
                        alert.buttons.last?.performClick(nil)
                        return true
                    }
                    if didPresent { timer.invalidate() }
                }
                RunLoop.main.add(cancel, forMode: .modalPanel)
                defer { cancel.invalidate() }
                let response = alert.runModal()
                XCTAssertTrue(sawModal)
                XCTAssertNil(WebInteractionPermissionAlert.selectedPermission(response: response, missing: missing))
            }
        }
    }

    private static func assertCenteredHeader(
        _ alert: NSAlert, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let content = try XCTUnwrap(alert.window.contentView, file: file, line: line)
        let icon = try XCTUnwrap(content.subviews.compactMap { $0 as? NSImageView }.first, file: file, line: line)
        let title = try XCTUnwrap(content.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == alert.messageText }, file: file, line: line)
        XCTAssertEqual(content.convert(icon.bounds, from: icon).midX, content.bounds.midX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(content.convert(title.bounds, from: title).midX, content.bounds.midX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(title.alignment, .center, file: file, line: line)
        let renderedTitle = title.attributedStringValue
        renderedTitle.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: renderedTitle.length)) { value, _, _ in
            XCTAssertEqual((value as? NSParagraphStyle)?.alignment, .center,
                           "The rendered paragraph must be centered, not only the text field", file: file, line: line)
        }
    }

    private func assertUnchecked(_ fixture: SettingsPresentationFixture) throws {
        XCTAssertFalse(fixture.model.library.settings.webInteractionEnabled)
        XCTAssertFalse(try fixture.model.store.load().settings.webInteractionEnabled)
        let selected: NSNumber? = try fixture.element("网页交互", role: .checkBox).accessibilityValue?()
        XCTAssertEqual(selected?.boolValue, false)
    }
}

@MainActor
private final class PermissionModalObservation {
    let checkbox: AnyObject
    var sawModal = false

    init(checkbox: AnyObject) { self.checkbox = checkbox }
}
