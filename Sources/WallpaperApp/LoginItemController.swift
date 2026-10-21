import Combine
import ServiceManagement
import WallpaperCore

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var failure: PresentedFailure?
    @Published private(set) var isChanging = false
    @Published private(set) var isShuttingDown = false
    private let service: any LoginItemServicing

    init(service: any LoginItemServicing) {
        self.service = service
        status = service.status
    }

    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var canChange: Bool {
        !isChanging && !isShuttingDown
            && (status == .enabled || status == .notRegistered || status == .requiresApproval || status == .notFound)
    }
    var statusMessage: String {
        switch status {
        case .notRegistered: return "登录时自动恢复壁纸，不打开管理窗口。"
        case .enabled: return "已开启：登录时自动恢复壁纸，不打开管理窗口。"
        case .requiresApproval: return "等待系统允许，请在系统登录项设置中允许此应用。"
        case .notFound: return "系统尚未找到登录项，可尝试开启；若失败，请查看错误详情。"
        @unknown default: return "无法识别系统返回的登录项状态（\(status.rawValue)）。"
        }
    }

    func refresh() { status = service.status }
    func openSystemSettings() { service.openSystemSettings() }
    func shutdown() { isShuttingDown = true }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard !isChanging, !isShuttingDown else {
            failure = PresentedFailure(title: "登录项设置未完成", summary: isShuttingDown
                ? "应用正在退出，无法修改登录项。" : "登录项操作尚未完成，请稍候。")
            return false
        }
        refresh()
        // A valid main app can report notFound before its first registration.
        // Let an explicit request reach the API; only its queried result confirms success.
        guard canChange else {
            failure = PresentedFailure(title: "登录项设置未完成", summary: statusMessage)
            return false
        }
        guard enabled != isRequested else { failure = nil; return true }
        isChanging = true
        defer { refresh(); isChanging = false }
        do {
            // The synchronous APIs run on MainActor, so termination cannot abandon an in-flight operation.
            if enabled { try service.register() } else { try service.unregister() }
            refresh()
            guard enabled ? isRequested : status == .notRegistered else {
                throw WallpaperError("系统尚未确认登录项变更。", diagnostic: "SMAppService status: \(status.rawValue)")
            }
            failure = nil
            return true
        } catch {
            failure = PresentedFailure(title: "登录项设置未完成",
                summary: enabled ? "无法开启登录自启动，请检查系统登录项设置。" : "无法关闭登录自启动，请检查系统登录项设置。",
                diagnostics: FailureDiagnostics.describe(error))
            return false
        }
    }
}
