import AppKit
import SwiftUI
import WallpaperCore

struct WindowGlassBackground: View {
    @Localized private var l10n
    let appearance: AppAppearanceSettings
    let reducesTransparency: Bool
    var receivesTransparentClicks = false
    var captureWallpaper: WallpaperSnapshotCapture = { try WallpaperSnapshot.systemWallpaper(on: $0) }
    var makeWallpaperMirror: WallpaperMirrorFactory?
    @StateObject private var fullScreen = FullScreenWallpaperState()

    var body: some View {
        let opacity = reducesTransparency ? 1 : 1 - appearance.transparency
        ZStack {
            ClearWindowBackground(receivesTransparentClicks: receivesTransparentClicks)
            FullScreenWallpaperObserver(state: fullScreen, capture: captureWallpaper, makeMirror: makeWallpaperMirror)
            if let mirror = fullScreen.mirror {
                WallpaperMirrorPresentation(view: mirror.view).id(ObjectIdentifier(mirror))
            } else if let image = fullScreen.image {
                FrozenWallpaperImage(image: image)
            }
            if opacity > 0 && opacity < 1 {
                glassMaterial.opacity(opacity)
            }
            Color(nsColor: .windowBackgroundColor).opacity(opacity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelPendingPresentationsForQuit)) { _ in
            fullScreen.failure = nil
        }
        .alert(l10n.text(fullScreen.failure?.title ?? "全屏背景无法显示"), isPresented: Binding(
            get: { fullScreen.failure != nil }, set: { if !$0 { fullScreen.failure = nil } }
        ), presenting: fullScreen.failure) { _ in
            Button(l10n("好"), role: .cancel) { fullScreen.failure = nil }
        } message: { failure in Text(l10n.failureDescription(failure)) }
    }

    @ViewBuilder
    private var glassMaterial: some View {
        let backdrop = NativeVisualEffectBackground(
            material: appearance.blur == .frosted ? .sidebar : .titlebar,
            blendingMode: fullScreen.hasBackground ? .withinWindow : .behindWindow)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(appearance.blur == .frosted ? .regular : .clear, in: Rectangle())
                .background {
                    // An extra titlebar material darkens clear glass until it resembles
                    // regular glass in inactive dark windows. Only frosted needs this blur layer.
                    if appearance.blur == .frosted { backdrop }
                }
        } else {
            backdrop
        }
    }
}

struct ClearWindowBackground: NSViewRepresentable {
    let receivesTransparentClicks: Bool
    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) {
        view.receivesTransparentClicks = receivesTransparentClicks
        view.configureWindow()
    }

    final class WindowView: NSView {
        var receivesTransparentClicks = false
        private var preparesFirstFrame = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.willBeginSheetNotification, object: nil)
            if window != nil {
                NotificationCenter.default.addObserver(self, selector: #selector(sheetWillBegin(_:)),
                    name: NSWindow.willBeginSheetNotification, object: nil)
            }
            preparesFirstFrame = window != nil
            configureWindow()
            // Sheet presentation installs its frame material after attaching our view.
            DispatchQueue.main.async { [weak self] in self?.configureWindow() }
        }

        @objc private func sheetWillBegin(_ notification: Notification) {
            // SwiftUI's sheet exists before the parent attaches it; AppKit has
            // already installed the native material when it posts this event.
            guard window?.isSheet == true else { return }
            configureWindow()
        }

        override func viewWillDraw() {
            super.viewWillDraw()
            guard preparesFirstFrame else { return }
            preparesFirstFrame = false
            // AppKit can install an opaque sheet material after attachment but before the first frame.
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            Self.configure(window, receivesTransparentClicks: receivesTransparentClicks)
        }

        private static func configure(_ window: NSWindow, receivesTransparentClicks: Bool) {
            // Removing glass alone exposes AppKit's opaque window and title-bar fill.
            window.isOpaque = false
            // WindowServer passes fully clear pixels through, including native title-bar
            // buttons and full-screen list-row gaps. Use the approved one-step alpha across
            // click-receiving transparent windows instead of painting individual controls.
            window.backgroundColor = receivesTransparentClicks ? .black.withAlphaComponent(1.0 / 255) : .clear
            window.titlebarAppearsTransparent = true
            // Native full screen otherwise keeps a separate opaque toolbar strip
            // above the glass-backed SwiftUI content.
            window.styleMask.insert(.fullSizeContentView)
            // AppKit adds its own sheet material beside the content view, even with
            // a clear presentation background. Our saved appearance supplies that surface.
            guard let frame = window.contentView?.superview else { return }
            for effect in frame.subviews.compactMap({ $0 as? NSVisualEffectView }) where effect.material == .sheet {
                effect.isHidden = true
            }
        }
    }
}
