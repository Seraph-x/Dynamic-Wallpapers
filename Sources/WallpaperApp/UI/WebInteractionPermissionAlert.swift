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
        // NSAlert permits layout customization after layout(), but has no header alignment property.
        alert.layout()
        guard let contentView = alert.window.contentView,
              let iconView = contentView.subviews.compactMap({ $0 as? NSImageView }).first,
              let titleView = contentView.subviews.compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == alert.messageText }) else {
            preconditionFailure("NSAlert did not create the permission dialog's icon and title views")
        }
        titleView.alignment = .center
        // The native attributed paragraph style overrides the text field's alignment.
        let originalTitle = titleView.attributedStringValue
        let centeredTitle = NSMutableAttributedString(attributedString: originalTitle)
        originalTitle.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: originalTitle.length)) { value, range, _ in
            let style = NSMutableParagraphStyle()
            if let nativeStyle = value as? NSParagraphStyle { style.setParagraphStyle(nativeStyle) }
            style.alignment = .center
            centeredTitle.addAttribute(.paragraphStyle, value: style, range: range)
        }
        titleView.attributedStringValue = centeredTitle
        let headerViews: [NSView] = [iconView, titleView]
        for view in headerViews {
            view.setFrameOrigin(NSPoint(x: contentView.bounds.midX - view.frame.width / 2, y: view.frame.minY))
        }
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
