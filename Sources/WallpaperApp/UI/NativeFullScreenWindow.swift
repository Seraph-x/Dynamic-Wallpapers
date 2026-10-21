import AppKit
import SwiftUI

struct NativeFullScreenWindow: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            // SwiftUI's automatic behavior disables native full screen in accessory mode.
            // A permanently visible full-screen toolbar lives above the content, so the
            // wallpaper-backed glass cannot extend into it. Use the system's on-hover
            // presentation so the content occupies the entire screen while the toolbar
            // remains available at the top edge.
            content
                .windowFullScreenBehavior(.enabled)
                .windowToolbarFullScreenVisibility(.onHover)
                .background(NativeFullScreenWindowBridge(configuresLegacyBehavior: false))
        } else {
            content.background(NativeFullScreenWindowBridge(configuresLegacyBehavior: true))
        }
    }
}

// Only attach this bridge to a management window. On macOS 14 it also performs
// the AppKit full-screen opt-in that SwiftUI exposes directly on newer systems.
struct NativeFullScreenWindowBridge: NSViewRepresentable {
    let configuresLegacyBehavior: Bool

    func makeNSView(context: Context) -> WindowView {
        WindowView(configuresLegacyBehavior: configuresLegacyBehavior)
    }
    func updateNSView(_ view: WindowView, context: Context) { view.configureWindow() }
    static func dismantleNSView(_ view: WindowView, coordinator: ()) { view.detach() }

    final class WindowView: NSView {
        private let configuresLegacyBehavior: Bool
        private weak var observedWindow: NSWindow?
        private var delegateProxy: FullScreenWindowDelegateProxy?

        init(configuresLegacyBehavior: Bool) {
            self.configuresLegacyBehavior = configuresLegacyBehavior
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observedWindow else {
                configureWindow()
                return
            }
            detach()
            guard let window else { return }
            observedWindow = window
            let proxy = FullScreenWindowDelegateProxy(originalDelegate: window.delegate)
            delegateProxy = proxy
            window.delegate = proxy
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(configureAfterSceneUpdate),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(configureAfterSceneUpdate),
                               name: NSApplication.didFinishLaunchingNotification, object: NSApplication.shared)
            configureWindow()
        }

        @objc private func configureAfterSceneUpdate() {
            // Launch/activation can apply the scene's automatic window flags first.
            DispatchQueue.main.async { [weak self] in self?.configureWindow() }
        }

        func configureWindow() {
            guard configuresLegacyBehavior, let window = observedWindow,
                  window.styleMask.contains(.resizable) else { return }
            var behavior = window.collectionBehavior
            behavior.subtract([.fullScreenNone, .fullScreenAuxiliary])
            behavior.insert(.fullScreenPrimary)
            if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if let observedWindow, let delegateProxy {
                delegateProxy.restoreWindowChromeForDetachment(from: observedWindow)
                if observedWindow.delegate === delegateProxy {
                    observedWindow.delegate = delegateProxy.originalDelegate
                }
            }
            delegateProxy = nil
            observedWindow = nil
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
