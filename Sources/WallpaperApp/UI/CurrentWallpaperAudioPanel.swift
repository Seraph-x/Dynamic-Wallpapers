import AppKit
import SwiftUI

@MainActor
final class CurrentWallpaperAudioPanel {
    private var panel: AudioPanelWindow?

    func show(model: AppModel, near location: NSPoint) {
        panel?.close()

        let content = CurrentWallpaperAudioMenu(model: model)
            .appInterfacePreferences(model)
            .padding(14)
            .frame(width: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        let hostingView = NSHostingView(rootView: content)
        let size = hostingView.fittingSize
        let panel = AudioPanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false

        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else {
            fatalError("Cannot present current wallpaper audio panel without a screen at \(location)")
        }
        let visible = screen.visibleFrame
        let x = min(max(location.x - size.width - 12, visible.minX), visible.maxX - size.width)
        let y = min(max(location.y - size.height / 2, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        self.panel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

private final class AudioPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
