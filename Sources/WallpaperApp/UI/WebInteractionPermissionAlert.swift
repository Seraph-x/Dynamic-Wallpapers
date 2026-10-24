import AppKit

@MainActor
enum WebInteractionPermissionAlert {
    static func makeAlert(missing: [WebInteractionPermission], localizer: AppLocalizer) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localizer("网页交互需要授权")
        let permissions = missing.map { "• \(localizer.text($0.title))" }.joined(separator: "\n")
        alert.informativeText = localizer("请在系统设置中允许以下权限：") + "\n" + permissions
            + "\n\n" + localizer("授权后，请返回菜单再次开启“网页交互”。")
        for permission in missing { alert.addButton(withTitle: localizer.text(permission.settingsTitle)) }
        alert.addButton(withTitle: localizer("取消")).keyEquivalent = "\u{1b}"
        layoutCenteredHeader(in: alert)
        return alert
    }

    static func layoutCenteredHeader(in alert: NSAlert) {
        AppBranding.centerAlertHeader(in: alert)
    }

    static func selectedPermission(response: NSApplication.ModalResponse,
                                   missing: [WebInteractionPermission]) -> WebInteractionPermission? {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return missing.indices.contains(index) ? missing[index] : nil
    }

    static func present(missing: [WebInteractionPermission], localizer: AppLocalizer) -> WebInteractionPermission? {
        let response = makeAlert(missing: missing, localizer: localizer).runModal()
        return selectedPermission(response: response, missing: missing)
    }
}
