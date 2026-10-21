import AppKit
import SwiftUI

struct ImportWallpaperCommand: Commands {
    private var l10n: AppLocalizer { model.localizer }
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.section == .screenSaver ? l10n("导入屏保素材…") : l10n("导入壁纸…")) {
                openWindow(id: "library")
                NSApplication.shared.activate(ignoringOtherApps: true)
                model.importFiles(purpose: model.section == .screenSaver ? .screenSaver : .wallpaper)
            }.keyboardShortcut("o")
                .disabled(model.importing || model.loadFailed || model.isShuttingDown)
        }
    }
}
