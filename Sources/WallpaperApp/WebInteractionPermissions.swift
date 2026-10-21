import AppKit
import ApplicationServices
import WallpaperCore

enum WebInteractionPermission: CaseIterable {
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .accessibility: return "辅助功能"
        case .inputMonitoring: return "输入监控"
        }
    }

    var settingsTitle: String {
        switch self {
        case .accessibility: return "打开辅助功能设置…"
        case .inputMonitoring: return "打开输入监控设置…"
        }
    }

    var settingsURL: URL {
        let pane: String
        switch self {
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

@MainActor
protocol WebInteractionPermissionServicing {
    var missingPermissions: [WebInteractionPermission] { get }
    func request(_ permission: WebInteractionPermission)
    func openSettings(for permission: WebInteractionPermission) throws
}

@MainActor
struct SystemWebInteractionPermissionService: WebInteractionPermissionServicing {
    private static let accessibilityPromptOption = "AXTrustedCheckOptionPrompt"

    var missingPermissions: [WebInteractionPermission] {
        var missing: [WebInteractionPermission] = []
        if !AXIsProcessTrusted() { missing.append(.accessibility) }
        if !CGPreflightListenEventAccess() { missing.append(.inputMonitoring) }
        return missing
    }

    func request(_ permission: WebInteractionPermission) {
        // Register the app with TCC only after the user chooses that authorization action.
        switch permission {
        case .accessibility:
            let options = [Self.accessibilityPromptOption: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    func openSettings(for permission: WebInteractionPermission) throws {
        guard NSWorkspace.shared.open(permission.settingsURL) else {
            throw WallpaperError("无法打开系统隐私设置。", diagnostic: permission.settingsURL.absoluteString)
        }
    }
}

enum WebInteractionSettingResult: Equatable {
    case updated
    case needsPermissions([WebInteractionPermission])
    case failed
}
