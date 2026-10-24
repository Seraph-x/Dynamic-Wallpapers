import AppKit

@MainActor enum EditorInstallPrompt {
    static func makeAlert(localizer: AppLocalizer) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational; alert.icon = AppBranding.applicationIcon
        alert.messageText = localizer("是否安装 Editor？")
        alert.informativeText = localizer("Editor 是独立应用。是否前往下载并安装？壁纸功能不需要安装它。")
        alert.addButton(withTitle:localizer("下载 Editor"))
        alert.addButton(withTitle:localizer("取消")).keyEquivalent = "\u{1b}"
        AppBranding.centerAlertHeader(in:alert)
        return alert
    }
}
