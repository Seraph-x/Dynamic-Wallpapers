import SwiftUI

struct StartupSettingsSection: View {
    @Localized private var l10n
    @ObservedObject var model: AppModel
    @ObservedObject private var loginItems: LoginItemController

    init(model: AppModel) {
        self.model = model
        loginItems = model.loginItems
    }

    var body: some View {
        Section(l10n("启动与运行")) {
            Toggle(l10n("登录时启动"), isOn: Binding(get: { loginItems.isRequested },
                set: { loginItems.setEnabled($0) }))
                .disabled(!loginItems.canChange || model.isShuttingDown)
            if loginItems.status == .requiresApproval {
                Button(l10n("打开系统登录项设置…"), action: loginItems.openSystemSettings)
            }
            Toggle(l10n("在 Dock 中显示应用图标"), isOn: Binding(
                get: { model.library.settings.showDockIcon }, set: { model.setShowDockIcon($0) }))
                .disabled(model.loadFailed || model.isShuttingDown)
                .help(l10n("关闭后，仅在管理窗口打开时显示 Dock 图标；关闭全部管理窗口后隐藏。"))
            if let failure = loginItems.failure { FailureNotice(failure: failure) }
            if let failure = model.presentationFailure { FailureNotice(failure: failure) }
        }
        .onAppear { loginItems.refresh() }
    }
}
