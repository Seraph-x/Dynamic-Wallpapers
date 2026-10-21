import AppKit
import SwiftUI

/// Keep reusable management windows with the desktop where the user invoked them.
struct ManagementWindowSpaceBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) { view.configureWindow() }

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                center.addObserver(self, selector: #selector(configureAfterSceneUpdate), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(configureAfterSceneUpdate),
                               name: NSApplication.didFinishLaunchingNotification, object: NSApplication.shared)
            configureWindow()
        }

        @objc private func configureAfterSceneUpdate() {
            // SwiftUI can restore its scene flags during activation; apply ours on the next main turn.
            DispatchQueue.main.async { [weak self] in self?.configureWindow() }
        }

        func configureWindow() {
            guard let window else { return }
            var behavior = window.collectionBehavior
            behavior.remove(.canJoinAllSpaces)
            behavior.insert(.moveToActiveSpace)
            if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
