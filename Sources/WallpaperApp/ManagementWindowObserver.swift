import AppKit

/// Track open management windows, not focus or occlusion: minimized/hidden windows
/// remain open, while desktop playback and menu-bar panels never own the app menu.
@MainActor
final class ManagementWindowObserver: NSObject {
    private let windows = NSHashTable<NSWindow>.weakObjects()
    private let onChange: (Bool) -> Void
    private var started = false
    private var hasOpenWindows = false

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            center.addObserver(self, selector: #selector(windowOpened(_:)), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(windowClosed(_:)),
                           name: NSWindow.willCloseNotification, object: nil)
        for window in NSApplication.shared.windows where window.isVisible || window.isMiniaturized {
            track(window)
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        started = false
        windows.removeAllObjects()
        publish()
    }

    @objc private func windowOpened(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        track(window)
    }

    private func track(_ window: NSWindow) {
        guard window.level == .normal, window.styleMask.contains(.titled), window.canBecomeMain else { return }
        windows.add(window)
        publish()
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // willClose arrives while isVisible can still be true. Never rescan visibility here.
        windows.remove(window)
        publish()
    }

    private func publish() {
        let hasOpenWindows = !windows.allObjects.isEmpty
        guard hasOpenWindows != self.hasOpenWindows else { return }
        self.hasOpenWindows = hasOpenWindows
        onChange(hasOpenWindows)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
